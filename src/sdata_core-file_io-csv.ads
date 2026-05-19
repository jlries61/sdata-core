--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package SData_Core.File_IO.CSV is

   procedure Parse_CSV (File_Name   : String;
                        Delimiter   : String  := ",";
                        Read_Header : Boolean := True;
                        Charset     : String  := "";
                        Skip_Rows   : Natural := 0;
                        Max_Rows    : Natural := 0;
                        Nscan_Rows  : Natural := 0);

   procedure Write_CSV (File_Name       : String;
                        Delimiter       : String  := ",";
                        Write_Header    : Boolean := True;
                        Allow_Overwrite : Boolean := True;
                        Charset         : String  := "");

end SData_Core.File_IO.CSV;