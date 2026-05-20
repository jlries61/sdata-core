--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Environment_Variables;
with Ada.Real_Time;
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
            declare
               Shell_Arg : constant String :=
                  (if Posix then "-c" else "/c");
               Args : GNAT.OS_Lib.Argument_List :=
                  (new String'(Shell_Arg), new String'(Command));
            begin
               if Timeout_Val > 0 then
                  --  Non-blocking spawn with a 1-second poll loop.
                  --  Kill the child and raise SData_Core.Script_Error if the limit expires.
                  declare
                     use Ada.Real_Time;
                     Pid   : constant GNAT.OS_Lib.Process_Id :=
                        GNAT.OS_Lib.Non_Blocking_Spawn (Path.all, Args);
                     Start : constant Time      := Clock;
                     Limit : constant Time_Span := Seconds (Timeout_Val);
                     Done  : GNAT.OS_Lib.Process_Id;
                     OK    : Boolean;
                  begin
                     for I in Args'Range loop Free (Args (I)); end loop;
                     if Pid = GNAT.OS_Lib.Invalid_Pid then
                        Success := False;
                     else
                        loop
                           delay 0.5;
                           GNAT.OS_Lib.Non_Blocking_Wait_Process (Done, OK);
                           exit when Done = Pid;
                           if Clock - Start >= Limit then
                              GNAT.OS_Lib.Kill (Pid);
                              GNAT.OS_Lib.Wait_Process (Done, OK);
                              declare
                                 T_Img : constant String := Timeout_Val'Image;
                                 T_Str : constant String :=
                                    T_Img (T_Img'First + 1 .. T_Img'Last);
                              begin
                                 raise SData_Core.Script_Error with
                                    "SYSTEM command timed out after "
                                    & T_Str & " seconds";
                              end;
                           end if;
                        end loop;
                        Success := OK;
                     end if;
                  end;
               else
                  --  No timeout: block until the child exits.
                  GNAT.OS_Lib.Spawn (Path.all, Args, Success);
                  for I in Args'Range loop Free (Args (I)); end loop;
               end if;
            end;
            Free (Path);
         end;
      end if;
   end Shell_Execute;

end SData_Core.System;