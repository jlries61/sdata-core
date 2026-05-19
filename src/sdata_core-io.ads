--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package SData_Core.IO is

   procedure Put (Item : String);
   procedure Put_Line (Item : String);
   procedure New_Line;

   procedure Put_Error (Item : String);
   procedure Put_Line_Error (Item : String);

   procedure Open_Output (Filename : String);
   procedure Close_Output;
   function Is_Redirected return Boolean;

   procedure Set_Interactive (Val : Boolean);
   function Is_Interactive return Boolean;
   procedure Set_Local_Echo (Val : Boolean);

   --  External pager support (interactive mode only).

   Pager_Not_Found : exception;
   --  Raised by Set_Pager when the pager executable cannot be located on PATH.

   procedure Set_Pager (Cmd : String);
   --  Register an external pager command (e.g. "less -F" or "more").
   --  The first word is treated as the executable name and must be
   --  locatable on PATH; raises Pager_Not_Found otherwise.
   --  Has no effect unless interactive mode is active.

   procedure Flush_Pager_Buffer;
   --  Write accumulated console output to the external pager and clear
   --  the internal buffer.  In interactive mode with no external pager
   --  configured this resets the internal line counter.
   --  Always a no-op when the buffer is empty.

end SData_Core.IO;