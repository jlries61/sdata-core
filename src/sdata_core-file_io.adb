--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with SData_Core.IO;                use SData_Core.IO;
with SData_Core.Table;             use SData_Core.Table;
with SData_Core.Values;            use SData_Core.Values;
with SData_Core.File_IO.CSV;       use SData_Core.File_IO.CSV;
with SData_Core.File_IO.ODF;       use SData_Core.File_IO.ODF;
with SData_Core.File_IO.OOXML;     use SData_Core.File_IO.OOXML;

package body SData_Core.File_IO is

   procedure Open_Input (File_Name   : String;
                         Fmt         : Format_Type;
                         Sheet_Name  : String  := "";
                         Delimiter   : String  := ",";
                         Read_Header : Boolean := True;
                         Charset     : String  := "";
                         Skip_Rows   : Natural := 0;
                         Max_Rows    : Natural := 0;
                         Nscan_Rows  : Natural := 0) is
      Actual_Fmt : Format_Type := Fmt;
      Ext_Idx    : Natural := 0;
      U_Name     : constant String := To_Upper (File_Name);
   begin
      if U_Name = "MOCK" or else U_Name = "MOCK_DATA" then
         Clear;
         Add_Column ("ID",     Col_Integer);
         Add_Column ("NAME$",  Col_String);
         Add_Column ("SALARY", Col_Numeric);
         for I in 1 .. 3 loop
            Add_Row;
            Set_Value (I, "ID",
               (Kind => Val_Integer, Int_Val => I));
            Set_Value (I, "SALARY",
               (Kind    => Val_Numeric,
                Num_Val => 50000.0 + Float (I - 1) * 10000.0));
         end loop;
         Set_Value (1, "NAME$",
            (Kind    => Val_String,
             Str_Val => To_Unbounded_String ("Alice")));
         Set_Value (2, "NAME$",
            (Kind    => Val_String,
             Str_Val => To_Unbounded_String ("Bob")));
         Set_Value (3, "NAME$",
            (Kind    => Val_String,
             Str_Val => To_Unbounded_String ("Charlie")));
         if not SData_Core.Config.Quiet_Mode then
            Put_Line ("Generating mock data...");
         end if;
         return;
      end if;

      for I in reverse File_Name'Range loop
         if File_Name (I) = '.' then
            Ext_Idx := I;
            exit;
         end if;
      end loop;

      if Ext_Idx > 0 then
         declare
            Ext : constant String := File_Name (Ext_Idx + 1 .. File_Name'Last);
         begin
            if Ext = "csv" then
               Actual_Fmt := SData_Core.Config.CSV;
            elsif Ext = "ods" or else Ext = "odf" then
               Actual_Fmt := SData_Core.Config.ODF;
            elsif Ext = "xlsx" or else Ext = "ooxml" then
               Actual_Fmt := SData_Core.Config.OOXML;
            end if;
         end;
      end if;

      case Actual_Fmt is
         when SData_Core.Config.CSV =>
            Parse_CSV (File_Name, Delimiter, Read_Header, Charset,
                       Skip_Rows, Max_Rows, Nscan_Rows);
         when SData_Core.Config.ODF =>
            Parse_ODF (File_Name, Sheet_Name, Skip_Rows, Max_Rows);
         when SData_Core.Config.OOXML =>
            Parse_OOXML (File_Name, Sheet_Name, Skip_Rows, Max_Rows);
      end case;

      if not SData_Core.Config.Quiet_Mode then
         Put_Line ("Dataset opened: " & File_Name);
      end if;
   end Open_Input;

   -----------------
   -- Open_Output --
   -----------------
   procedure Open_Output (File_Name       : String;
                          Fmt             : Format_Type;
                          Sheet_Name      : String  := "";
                          Delimiter       : String  := ",";
                          Write_Header    : Boolean := True;
                          Allow_Overwrite : Boolean := True;
                          Charset         : String  := "";
                          Decimals        : Integer := -1) is
      Actual_Fmt : Format_Type := Fmt;
      Ext_Idx    : Natural := 0;
      Sname      : constant String :=
         (if Sheet_Name = "" then "Sheet1" else Sheet_Name);
   begin
      for I in reverse File_Name'Range loop
         if File_Name (I) = '.' then
            Ext_Idx := I;
            exit;
         end if;
      end loop;

      if Ext_Idx > 0 then
         declare
            Ext : constant String := File_Name (Ext_Idx + 1 .. File_Name'Last);
         begin
            if Ext = "csv" then
               Actual_Fmt := SData_Core.Config.CSV;
            elsif Ext = "ods" or else Ext = "odf" then
               Actual_Fmt := SData_Core.Config.ODF;
            elsif Ext = "xlsx" or else Ext = "ooxml" then
               Actual_Fmt := SData_Core.Config.OOXML;
            end if;
         end;
      end if;

      case Actual_Fmt is
         when SData_Core.Config.CSV =>
            Write_CSV (File_Name, Delimiter, Write_Header, Allow_Overwrite,
                       Charset, Decimals);
         when SData_Core.Config.ODF =>
            Write_ODF (File_Name, Sname, Decimals);
         when SData_Core.Config.OOXML =>
            Write_OOXML (File_Name, Sname, Decimals);
      end case;
   end Open_Output;

end SData_Core.File_IO;