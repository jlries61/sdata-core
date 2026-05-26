--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Environment_Variables;
with GNAT.OS_Lib; use GNAT.OS_Lib;
with Interfaces.C; use type Interfaces.C.int;
with SData_Core.Config.Runtime;

package body SData_Core.System is

   Is_Windows : constant Boolean := GNAT.OS_Lib.Directory_Separator = '\';

   function C_Is_System_Account return Interfaces.C.int;
   pragma Import (C, C_Is_System_Account, "sdata_is_system_account");

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

   procedure Shell_Execute (Command : String := ""; Success : out Boolean) is
   begin
      if Command = "" then
         --  Interactive shell: no timeout applied.
         declare
            Path : GNAT.OS_Lib.String_Access;
         begin
            Resolve_Interactive_Shell (Path);
            GNAT.OS_Lib.Spawn (Path.all, (1 .. 0 => null), Success);
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
            --  utility from GNU coreutils, which is present on Linux, macOS,
            --  and Cygwin (i.e. wherever a POSIX shell is available).  When
            --  it kills the inner command it exits with status 124, which we
            --  translate back into Script_Error to preserve the previous
            --  contract.  On the cmd.exe path (Windows with no bash on PATH)
            --  the timeout is not enforced; the prior poll-loop implementation
            --  was effectively broken there as well, so this is no regression.
            declare
               Shell_Arg   : constant String :=
                  (if Posix then "-c" else "/c");
               T_Img       : constant String := Timeout_Val'Image;
               T_Str       : constant String :=
                  T_Img (T_Img'First + 1 .. T_Img'Last);
               Use_Timeout : constant Boolean :=
                  Timeout_Val > 0 and then Posix;
               Wrapped     : constant String :=
                  (if Use_Timeout
                   then "timeout " & T_Str & " " & Command
                   else Command);
               Args        : GNAT.OS_Lib.Argument_List :=
                  (new String'(Shell_Arg), new String'(Wrapped));
               Status      : Integer;
            begin
               Status := GNAT.OS_Lib.Spawn (Path.all, Args);
               for I in Args'Range loop Free (Args (I)); end loop;
               if Use_Timeout and then Status = 124 then
                  raise SData_Core.Script_Error with
                     "SYSTEM command timed out after "
                     & T_Str & " seconds";
               end if;
               Success := (Status = 0);
            end;
            Free (Path);
         end;
      end if;
   end Shell_Execute;

end SData_Core.System;