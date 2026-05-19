--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with GNAT.Ctrl_C;
with GNAT.OS_Lib;

package body SData_Core.Signals is

   procedure Register_Cleanup_Path (Path : String) is
   begin
      Signal_Trap.Set_Path (Path);
   end Register_Cleanup_Path;

   procedure Clear_Cleanup_Path is
   begin
      Signal_Trap.Clear_Path;
   end Clear_Cleanup_Path;

   --  Called by GNAT.Ctrl_C_Handlers on SIGINT (Ctrl-C).
   procedure On_Ctrl_C is
      Path : constant String := Signal_Trap.Current_Path;
      S    : Boolean;
      pragma Warnings (Off, S);
   begin
      if Path'Length > 0 then
         GNAT.OS_Lib.Delete_File (Path, S);
      end if;
      GNAT.OS_Lib.OS_Exit (128 + 2);
   end On_Ctrl_C;

   protected body Signal_Trap is

      procedure Set_Path (Path : String) is
      begin
         Temp_Path (1 .. Path'Length) := Path;
         Temp_Path_Len := Path'Length;
      end Set_Path;

      procedure Clear_Path is
      begin
         Temp_Path_Len := 0;
      end Clear_Path;

      function Current_Path return String is
      begin
         return Temp_Path (1 .. Temp_Path_Len);
      end Current_Path;

      procedure On_SIGTERM is
         S : Boolean;
         pragma Warnings (Off, S);
      begin
         if Temp_Path_Len > 0 then
            GNAT.OS_Lib.Delete_File (Temp_Path (1 .. Temp_Path_Len), S);
         end if;
         GNAT.OS_Lib.OS_Exit (128 + 15);
      end On_SIGTERM;

   end Signal_Trap;

begin
   --  Register the Ctrl-C (SIGINT) handler at package elaboration time.
   --  SIGTERM is registered via pragma Attach_Handler in the protected object.
   GNAT.Ctrl_C.Install_Handler (On_Ctrl_C'Access);
end SData_Core.Signals;