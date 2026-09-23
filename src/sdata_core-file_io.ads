--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.File_IO implements the File I/O Layer. It provides the capability
--  to read from and write to various dataset formats: CSV, ODS, and XLSX.
--  It supports automatic format detection and utilizes external utilities (ssconvert)
--  or native logic for specific file types.

with SData_Core.Config; use SData_Core.Config;
with SData_Core.Table;

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
   --  Missing_Tokens (CSV only -- ADR-0026): a comma-separated list of
   --  literal strings that, when a field's value matches one exactly, are
   --  treated as missing in addition to the built-in "" and ".". ODF/OOXML
   --  have no NSCAN-window inference to interact with (see Parse_ODF /
   --  Parse_OOXML) and are unaffected by this parameter.
   procedure Open_Input (File_Name      : String;
                         Fmt            : Format_Type;
                         Sheet_Name     : String  := "";
                         Delimiter      : String  := ",";
                         Read_Header    : Boolean := True;
                         Charset        : String  := "";
                         Skip_Rows      : Natural := 0;
                         Max_Rows       : Natural := 0;
                         Nscan_Rows     : Natural := 0;
                         Missing_Tokens : String  := "");
   pragma Annotate (GNATcheck, Exempt_Off, "Too_Many_Parameters");

   --  Writes the current Data Table to a file.
   --  Sheet_Name sets the output sheet name in ODF/OOXML files (default: "Sheet1").
   --  Delimiter, Write_Header, and Allow_Overwrite apply to CSV format only.
   --  Charset specifies the output character encoding ("", "AUTO", "UTF-8", "UTF-16", "ASCII").
   --  View (default: SData_Core.Table.Default_View, ADR-071) selects which
   --  table is written -- the global Data_Table singleton by default, or a
   --  caller-supplied Table_View (e.g. SData_Core.Table.Output_View) so a
   --  caller can write a table other than Data_Table without installing it
   --  as Data_Table first. See SData_Core.Table.Table_View.
   --  Missing_Token (CSV/ODF/OOXML -- ADR-0026): a single literal string
   --  written for a missing cell instead of leaving it blank (CSV) / empty
   --  (ODF/OOXML). "" (the default) is today's unchanged blank/empty output.
   procedure Open_Output (File_Name       : String;
                          Fmt             : Format_Type;
                          Sheet_Name      : String  := "";
                          Delimiter       : String  := ",";
                          Write_Header    : Boolean := True;
                          Allow_Overwrite : Boolean := True;
                          Charset         : String  := "";
                          Decimals        : Integer := -1;
                          Missing_Token   : String  := "";
                          View            : SData_Core.Table.Table_View :=
                             SData_Core.Table.Default_View);

end SData_Core.File_IO;