--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package SData_Core.File_IO.ODF is

   procedure Parse_ODF (File_Name  : String;
                        Sheet_Name : String  := "";
                        Skip_Rows  : Natural := 0;
                        Max_Rows   : Natural := 0);

   procedure Write_ODF (File_Name  : String;
                        Sheet_Name : String := "Sheet1");

end SData_Core.File_IO.ODF;