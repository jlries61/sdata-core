--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.File_IO implements the File I/O Layer. It provides the capability 
--  to read from and write to various dataset formats: CSV, ODS, and XLSX.
--  It supports automatic format detection and utilizes external utilities (ssconvert)
--  or native logic for specific file types.

with SData_Core.Config; use SData_Core.Config;

package SData_Core.File_IO is

   --  Raised by Write_CSV when Allow_Overwrite = False and the target exists.
   Save_Refused : exception;

   --  Loads a dataset into the global Data Table.
   --  The 'Fmt' parameter serves as a default if format cannot be detected from the extension.
   --  Sheet_Name selects a specific sheet by name in ODF/OOXML files; empty string = first sheet.
   --  Delimiter and Read_Header apply to CSV format only.
   --  Charset specifies the character encoding ("", "AUTO", "UTF-8", "UTF-16", "ASCII").
   pragma Annotate (GNATcheck, Exempt_On, "Too_Many_Parameters",
                    "Format-agnostic API; parameters 3-9 are optional with safe defaults "
                    & "and all callers use named notation");
   procedure Open_Input (File_Name   : String;
                         Fmt         : Format_Type;
                         Sheet_Name  : String  := "";
                         Delimiter   : String  := ",";
                         Read_Header : Boolean := True;
                         Charset     : String  := "";
                         Skip_Rows   : Natural := 0;
                         Max_Rows    : Natural := 0;
                         Nscan_Rows  : Natural := 0);
   pragma Annotate (GNATcheck, Exempt_Off, "Too_Many_Parameters");

   --  Writes the current Data Table to a file.
   --  Sheet_Name sets the output sheet name in ODF/OOXML files (default: "Sheet1").
   --  Delimiter, Write_Header, and Allow_Overwrite apply to CSV format only.
   --  Charset specifies the output character encoding ("", "AUTO", "UTF-8", "UTF-16", "ASCII").
   procedure Open_Output (File_Name       : String;
                          Fmt             : Format_Type;
                          Sheet_Name      : String  := "";
                          Delimiter       : String  := ",";
                          Write_Header    : Boolean := True;
                          Allow_Overwrite : Boolean := True;
                          Charset         : String  := "");

end SData_Core.File_IO;