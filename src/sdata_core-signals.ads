--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Signals registers POSIX signal handlers that delete the
--  SQLite backing-store temp file before the process exits on SIGTERM or
--  SIGINT (Ctrl-C).
--
--  SIGTERM is handled via Ada.Interrupts pragma Attach_Handler.
--  SIGINT is reserved by the GNAT runtime; it is handled via
--  GNAT.Ctrl_C_Handlers, which cooperates with the Ada runtime.
--
--  SIGKILL cannot be caught by any mechanism — that is a kernel constraint.
--  SIGTERM (kill/OOM killer) and SIGINT (Ctrl-C) cover the majority of
--  abnormal-termination cases that would leave orphaned temp files.

with Ada.Interrupts.Names;

package SData_Core.Signals is

   --  Record the backing-store temp file path so the signal handlers can
   --  delete it.  Called by SData.Table when the SQLite store is activated.
   procedure Register_Cleanup_Path (Path : String);

   --  Clear the registered path.  Called by SData.Table when the backing
   --  store is deactivated (Finalize has already deleted the file).
   procedure Clear_Cleanup_Path;

private

   protected Signal_Trap is
      procedure Set_Path (Path : String);
      procedure Clear_Path;
      function  Current_Path return String;
      procedure On_SIGTERM;
      pragma Attach_Handler (On_SIGTERM, Ada.Interrupts.Names.SIGTERM);
   private
      Temp_Path     : String (1 .. Max_Path_Len) := (others => ' ');
      Temp_Path_Len : Natural            := 0;
   end Signal_Trap;

end SData_Core.Signals;