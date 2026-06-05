--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Environment_Variables;
with GNAT.OS_Lib; use GNAT.OS_Lib;
with Interfaces.C; use type Interfaces.C.int;
with SData_Core.Config.Runtime;

package body SData_Core.System is

   Is_Windows : constant Boolean := GNAT.OS_Lib.Directory_Separator = '\';

   function C_Is_System_Account return Interfaces.C.int;
   pragma Import (C, C_Is_System_Account, "sdata_is_system_account");

   --  Clear/restore the calling thread's signal mask around Spawn so that
   --  forked subprocesses do not inherit the GNAT runtime's blocked signal
   --  set (which otherwise breaks timeout(1)'s SIGALRM/SIGTERM delivery).
   procedure C_Clear_Sigmask;
   pragma Import (C, C_Clear_Sigmask, "sdata_clear_sigmask");
   procedure C_Restore_Sigmask;
   pragma Import (C, C_Restore_Sigmask, "sdata_restore_sigmask");

   function Running_As_System_Account return Boolean is
   begin
      return C_Is_System_Account /= 0;
   end Running_As_System_Account;

   --  Resolve the shell to use for SYSTEM/SHELL invocations.
   --  Posix is True when the resolved shell takes "-c" (POSIX shells),
   --  False when it takes "/c" (cmd.exe). Path must be Free'd by caller.
   --
   --  On Windows we look up bash and sh on PATH first so that MSYS/MinGW
   --  installations get POSIX quoting semantics; we only fall back to
   --  COMSPEC/cmd.exe when no POSIX shell is available. SHELL is not
   --  consulted because under MSYS it may carry a Unix-style path
   --  ("/usr/bin/bash") that the native Windows process loader cannot
   --  resolve.
   --
   --  On non-Windows we use /bin/sh for "-c" execution to avoid sourcing
   --  the user's login profile, matching the previous behaviour.
   procedure Resolve_Shell (Path  : out GNAT.OS_Lib.String_Access;
                            Posix : out Boolean) is
   begin
      if Is_Windows then
         Path := GNAT.OS_Lib.Locate_Exec_On_Path ("bash");
         if Path = null then
            Path := GNAT.OS_Lib.Locate_Exec_On_Path ("sh");
         end if;
         if Path /= null then
            Posix := True;
            return;
         end if;
         declare
            Comspec : constant String :=
               (if Ada.Environment_Variables.Exists ("COMSPEC")
                then Ada.Environment_Variables.Value ("COMSPEC")
                else "cmd.exe");
         begin
            Path  := new String'(Comspec);
            Posix := False;
         end;
      else
         Path  := new String'("/bin/sh");
         Posix := True;
      end if;
   end Resolve_Shell;

   --  Resolve an interactive shell (no command). Honours SHELL on
   --  non-Windows; on Windows prefers bash, then sh, then COMSPEC.
   --  Path must be Free'd by caller.
   procedure Resolve_Interactive_Shell (Path : out GNAT.OS_Lib.String_Access) is
      Posix_Unused : Boolean;
   begin
      if Is_Windows then
         Resolve_Shell (Path, Posix_Unused);
      else
         declare
            Shell : constant String :=
               (if Ada.Environment_Variables.Exists ("SHELL")
                then Ada.Environment_Variables.Value ("SHELL")
                else "/bin/sh");
         begin
            Path := new String'(Shell);
         end;
      end if;
   end Resolve_Interactive_Shell;

   --  Resolve the timeout(1) command used to bound SYSTEM execution.
   --  Prefer GNU coreutils: on Linux it is named `timeout`; on macOS/BSD,
   --  where the bare `timeout` may be a different, noisier utility (it prints
   --  an "aborting command" banner and SIGKILLs the command), GNU coreutils
   --  installs it as `gtimeout`.  GNU timeout is silent and returns 124, which
   --  keeps the SYSTEM-timeout output identical across platforms.  Falls back
   --  to `timeout` when no `gtimeout` is on PATH.  Returns "" when neither is
   --  found, so the caller can fail loudly rather than run the command
   --  unbounded (silently ignoring the requested timeout).
   function Resolve_Timeout_Cmd return String is
      G : GNAT.OS_Lib.String_Access :=
         GNAT.OS_Lib.Locate_Exec_On_Path ("gtimeout");
      T : GNAT.OS_Lib.String_Access;
   begin
      if G /= null then
         Free (G);
         return "gtimeout";
      end if;
      T := GNAT.OS_Lib.Locate_Exec_On_Path ("timeout");
      if T /= null then
         Free (T);
         return "timeout";
      end if;
      return "";
   end Resolve_Timeout_Cmd;

   procedure Shell_Execute (Command : String := ""; Success : out Boolean) is
   begin
      if Command = "" then
         --  Interactive shell: no timeout applied.
         declare
            Path : GNAT.OS_Lib.String_Access;
         begin
            Resolve_Interactive_Shell (Path);
            C_Clear_Sigmask;
            GNAT.OS_Lib.Spawn (Path.all, (1 .. 0 => null), Success);
            C_Restore_Sigmask;
            Free (Path);
         end;
      else
         declare
            Timeout_Val : constant Natural :=
               SData_Core.Config.Runtime.Options_Shell_Timeout;
            Path  : GNAT.OS_Lib.String_Access;
            Posix : Boolean;
         begin
            Resolve_Shell (Path, Posix);
            --  Always use blocking Spawn.  GNAT's Non_Blocking_Spawn paired
            --  with Non_Blocking_Wait_Process does not reliably detect child
            --  termination on Cygwin/MinGW (the runtime's child-handle table
            --  appears not to be updated), which caused SYSTEM commands to
            --  hang for the full timeout in batch mode.  Blocking Spawn takes
            --  a different OS path (direct _spawnvp(_P_WAIT) on Windows) and
            --  works correctly there — it is what the interactive (timeout=0)
            --  path was already using.
            --
            --  Timeout enforcement is delegated to the shell-level `timeout(1)`
            --  utility, present wherever a POSIX shell is available (Linux,
            --  macOS, Cygwin).  Its exit status on a fired timeout is not
            --  portable: GNU coreutils returns 124, whereas the BSD/MacPorts
            --  variant SIGKILLs the command (and re-raises the signal on
            --  itself), which the shell reports as 128+9 = 137 (or 128+15 =
            --  143 had it used SIGTERM).  We treat all three as the timeout
            --  having fired and translate them back into Script_Error to
            --  preserve the previous contract.  On the cmd.exe path (Windows
            --  with no bash on PATH) the timeout is not enforced; the prior
            --  poll-loop implementation was effectively broken there as well,
            --  so this is no regression.
            --
            --  The wrapped command ends with "; exit $?" so the shell runs
            --  `timeout` as a child and then exits *normally* with its status.
            --  Without it, a shell invoked as `sh -c "timeout ..."` with a
            --  single command exec-optimises (the command replaces the shell
            --  process); when MacPorts timeout re-raises SIGKILL on itself the
            --  shell process dies by signal, and GNAT.OS_Lib.Spawn collapses
            --  any signal death to -1 — losing the 137/124 status we match on.
            --
            --  C_Clear_Sigmask/C_Restore_Sigmask bracket the Spawn so the
            --  forked child does not inherit the GNAT runtime's blocked
            --  signal set; without that, timeout(1) cannot receive its own
            --  SIGALRM nor signal the command it wraps, and never fires.
            declare
               Shell_Arg   : constant String :=
                  (if Posix then "-c" else "/c");
               T_Img       : constant String := Timeout_Val'Image;
               T_Str       : constant String :=
                  T_Img (T_Img'First + 1 .. T_Img'Last);
               Use_Timeout : constant Boolean :=
                  Timeout_Val > 0 and then Posix;
               Timeout_Cmd : constant String :=
                  (if Use_Timeout then Resolve_Timeout_Cmd else "");
            begin
               --  A requested timeout we cannot enforce must fail loudly,
               --  not run the command unbounded.  (Use_Timeout is already
               --  False when SHELLTIMEOUT is 0 or the shell is non-POSIX.)
               if Use_Timeout and then Timeout_Cmd = "" then
                  Free (Path);
                  raise SData_Core.Script_Error with
                     "OPTIONS SHELLTIMEOUT is set but no timeout(1) utility "
                     & "(timeout or gtimeout) was found on PATH to enforce it";
               end if;
               declare
                  Wrapped : constant String :=
                     (if Use_Timeout
                      then Timeout_Cmd & " " & T_Str & " "
                           & Command & "; exit $?"
                      else Command);
                  Args    : GNAT.OS_Lib.Argument_List :=
                     (new String'(Shell_Arg), new String'(Wrapped));
                  Status  : Integer;
               begin
                  C_Clear_Sigmask;
                  Status := GNAT.OS_Lib.Spawn (Path.all, Args);
                  C_Restore_Sigmask;
                  for I in Args'Range loop Free (Args (I)); end loop;
                  if Use_Timeout
                    and then (Status = 124      --  GNU coreutils timeout
                              or else Status = 137   --  killed via SIGKILL
                              or else Status = 143)  --  killed via SIGTERM
                  then
                     raise SData_Core.Script_Error with
                        "SYSTEM command timed out after "
                        & T_Str & " seconds";
                  end if;
                  Success := (Status = 0);
               end;
            end;
            Free (Path);
         end;
      end if;
   end Shell_Execute;

end SData_Core.System;