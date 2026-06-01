--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package SData_Core.System is
   procedure Shell_Execute (Command : String := ""; Success : out Boolean);
   function Running_As_System_Account return Boolean;
end SData_Core.System;