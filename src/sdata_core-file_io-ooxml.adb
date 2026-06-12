--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Strings.Fixed;       use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with SData_Core.IO;                use SData_Core.IO;
with SData_Core.Table;             use SData_Core.Table;
with SData_Core.Values;            use SData_Core.Values;
with GNAT.OS_Lib;
with Zip;
with UnZip;
with Zip.Create;
with DOM.Core;
with DOM.Core.Nodes;
with DOM.Core.Elements;
with DOM.Core.Documents;
with DOM.Readers;
with Input_Sources.File;
with SData_Core.Config;
with SData_Core.File_IO.Helpers;   use SData_Core.File_IO.Helpers;
with SData_Core.File_IO.ODF;

package body SData_Core.File_IO.OOXML is

   --  DOM traversal note: XML-Ada does not include an XPath engine.  All element
   --  lookups use Get_Elements_By_Tag_Name / Get_Elements_By_Tag_Name_NS and
   --  attribute accessors from DOM.Core.Elements.

   procedure Parse_OOXML (File_Name  : String;
                          Sheet_Name : String  := "";
                          Skip_Rows  : Natural := 0;
                          Max_Rows   : Natural := 0) is
      use DOM.Core;
      use DOM.Core.Nodes;
      use DOM.Core.Elements;

      Temp_Shared   : constant String := File_Name & ".sharedStrings.xml";
      Temp_Sheet    : constant String := File_Name & ".sheet.xml";
      Temp_Workbook : constant String := File_Name & ".workbook.xml";
      Temp_Rels     : constant String := File_Name & ".workbook.rels.xml";

      package String_Vectors is new Ada.Containers.Vectors
         (Index_Type   => Natural,
          Element_Type => Unbounded_String);
      Shared_Strings : String_Vectors.Vector;

      function Find_Sheet_XML_Path (Zip_Info : Zip.Zip_Info) return String is
         WB_Reader : DOM.Readers.Tree_Reader;
         WB_Input  : Input_Sources.File.File_Input;
         WB_Doc    : DOM.Core.Document;
         Sheets    : Node_List;
         Found_RId : Unbounded_String := Null_Unbounded_String;
         Success   : Boolean;
      begin
         begin
            UnZip.Extract (from => Zip_Info, what => "xl/workbook.xml",
                           rename => Temp_Workbook);
         exception
            when Zip.Entry_name_not_found =>
               return "xl/worksheets/sheet1.xml";
         end;

         Input_Sources.File.Open (Temp_Workbook, WB_Input);
         DOM.Readers.Parse (WB_Reader, WB_Input);
         WB_Doc := DOM.Readers.Get_Tree (WB_Reader);
         Input_Sources.File.Close (WB_Input);
         Sheets := DOM.Core.Documents.Get_Elements_By_Tag_Name
            (WB_Doc, "sheet");

         if Sheet_Name = "" then
            if Length (Sheets) > 0 then
               Found_RId := To_Unbounded_String (
                  Get_Attribute (DOM.Core.Element (Item (Sheets, 0)), "r:id"));
            end if;
         else
            for I in 0 .. Length (Sheets) - 1 loop
               if Get_Attribute (DOM.Core.Element (Item (Sheets, I)), "name")
                  = Sheet_Name
               then
                  Found_RId := To_Unbounded_String (
                     Get_Attribute (DOM.Core.Element (Item (Sheets, I)), "r:id"));
                  exit;
               end if;
            end loop;
         end if;

         Free (Sheets);
         DOM.Readers.Free (WB_Reader);
         GNAT.OS_Lib.Delete_File (Temp_Workbook, Success);

         if Length (Found_RId) = 0 then
            return "xl/worksheets/sheet1.xml";
         end if;

         declare
            RL_Reader : DOM.Readers.Tree_Reader;
            RL_Input  : Input_Sources.File.File_Input;
            RL_Doc    : DOM.Core.Document;
            RL_List   : Node_List;
            Found_Tgt : Unbounded_String := Null_Unbounded_String;
         begin
            begin
               UnZip.Extract (from => Zip_Info,
                              what => "xl/_rels/workbook.xml.rels",
                              rename => Temp_Rels);
            exception
               when Zip.Entry_name_not_found =>
                  return "xl/worksheets/sheet1.xml";
            end;

            Input_Sources.File.Open (Temp_Rels, RL_Input);
            DOM.Readers.Parse (RL_Reader, RL_Input);
            RL_Doc := DOM.Readers.Get_Tree (RL_Reader);
            Input_Sources.File.Close (RL_Input);
            RL_List := DOM.Core.Documents.Get_Elements_By_Tag_Name
               (RL_Doc, "Relationship");

            for I in 0 .. Length (RL_List) - 1 loop
               if Get_Attribute (DOM.Core.Element (Item (RL_List, I)), "Id")
                  = To_String (Found_RId)
               then
                  Found_Tgt := To_Unbounded_String (
                     Get_Attribute (DOM.Core.Element (Item (RL_List, I)),
                                    "Target"));
                  exit;
               end if;
            end loop;

            Free (RL_List);
            DOM.Readers.Free (RL_Reader);
            GNAT.OS_Lib.Delete_File (Temp_Rels, Success);

            if Length (Found_Tgt) = 0 then
               return "xl/worksheets/sheet1.xml";
            end if;
            return "xl/" & To_String (Found_Tgt);
         end;
      end Find_Sheet_XML_Path;

      procedure Load_Shared_Strings (Zip_Info : Zip.Zip_Info) is
         Reader   : DOM.Readers.Tree_Reader;
         Input    : Input_Sources.File.File_Input;
         Doc      : DOM.Core.Document;
         SI_Nodes, T_Nodes : Node_List;
         Success  : Boolean;
      begin
         begin
            UnZip.Extract (from => Zip_Info,
                           what => "xl/sharedStrings.xml",
                           rename => Temp_Shared);
         exception
            when Zip.Entry_name_not_found =>
               return; -- sharedStrings.xml is optional in OOXML
         end;

         Input_Sources.File.Open (Temp_Shared, Input);
         DOM.Readers.Parse (Reader, Input);
         Doc := DOM.Readers.Get_Tree (Reader);
         Input_Sources.File.Close (Input);

         SI_Nodes := DOM.Core.Documents.Get_Elements_By_Tag_Name (Doc, "si");
         for I in 0 .. Length (SI_Nodes) - 1 loop
            T_Nodes := Get_Elements_By_Tag_Name
               (DOM.Core.Element (Item (SI_Nodes, I)), "t");
            if Length (T_Nodes) > 0 then
               Shared_Strings.Append
                  (To_Unbounded_String (Get_Text (Item (T_Nodes, 0))));
            else
               Shared_Strings.Append (Null_Unbounded_String);
            end if;
            Free (T_Nodes);
         end loop;

         Free (SI_Nodes);
         DOM.Readers.Free (Reader);
         GNAT.OS_Lib.Delete_File (Temp_Shared, Success);
      exception
         when E : others =>
            if not SData_Core.Config.Quiet_Mode then
               Put_Line_Error
                  ("Warning: OOXML shared strings failed to load; " &
                   "string cells will be missing: " &
                   Ada.Exceptions.Exception_Message (E));
            end if;
      end Load_Shared_Strings;

      procedure Load_Sheet (Zip_Info : Zip.Zip_Info; Sheet_XML_Path : String) is
         Reader  : DOM.Readers.Tree_Reader;
         Input   : Input_Sources.File.File_Input;
         Doc     : DOM.Core.Document;
         Rows    : Node_List;
         Success : Boolean;

         function Get_Cell_Value (Cell_Node : Node) return Value is
            T_Attr  : constant String :=
               Get_Attribute (DOM.Core.Element (Cell_Node), "t");
            V_List  : Node_List :=
               Get_Elements_By_Tag_Name (DOM.Core.Element (Cell_Node), "v");
            IS_List : Node_List :=
               Get_Elements_By_Tag_Name (DOM.Core.Element (Cell_Node), "is");
         begin
            if Length (V_List) > 0 then
               declare
                  Val_Str : constant String := Get_Text (Item (V_List, 0));
               begin
                  Free (V_List); Free (IS_List);
                  if T_Attr = "s" then
                     declare
                        Idx : constant Natural := Natural'Value (Val_Str);
                     begin
                        if Idx < Natural (Shared_Strings.Length) then
                           declare
                              S : constant String :=
                                 To_String (Shared_Strings.Element (Idx));
                           begin
                              return (Kind    => Val_String,
                                      Str_Val => To_Unbounded_String (S));
                           end;
                        end if;
                     end;
                  elsif T_Attr = "str" then
                     declare
                        Inf : constant Value := Detect_Inf (Val_Str);
                     begin
                        if Inf.Kind /= Val_Missing then return Inf; end if;
                        return (Kind    => Val_String,
                                Str_Val => To_Unbounded_String (Val_Str));
                     end;
                  else
                     begin
                        return (Kind    => Val_Numeric,
                                Num_Val => Float'Value (Val_Str));
                     exception
                        when Constraint_Error => null;
                     end;
                  end if;
               end;
            elsif Length (IS_List) > 0 then
               declare
                  T_Nodes : Node_List := Get_Elements_By_Tag_Name
                     (DOM.Core.Element (Item (IS_List, 0)), "t");
               begin
                  if Length (T_Nodes) > 0 then
                     declare
                        S   : constant String := Get_Text (Item (T_Nodes, 0));
                        Inf : constant Value  := Detect_Inf (S);
                     begin
                        Free (T_Nodes); Free (V_List); Free (IS_List);
                        if Inf.Kind /= Val_Missing then return Inf; end if;
                        return (Kind    => Val_String,
                                Str_Val => To_Unbounded_String (S));
                     end;
                  end if;
                  Free (T_Nodes);
               end;
            end if;
            Free (V_List); Free (IS_List);
            return (Kind => Val_Missing);
         end Get_Cell_Value;

         procedure Collect_OOXML_Headers
            (Row0         : DOM.Core.Node;
             Col_Name_Vec : in out Name_Vecs.Vector) is
            Cells : DOM.Core.Node_List :=
               Get_Elements_By_Tag_Name (DOM.Core.Element (Row0), "c");
         begin
            for I in 0 .. Length (Cells) - 1 loop
               declare
                  V   : constant Value  := Get_Cell_Value (Item (Cells, I));
                  Idx : constant String :=
                     Trim (Integer (I + 1)'Img, Ada.Strings.Both);
                  Nam : constant String :=
                     (if V.Kind = Val_String
                      then SData_Core.Values.To_String (V)
                      else "COL" & Idx);
               begin
                  Col_Name_Vec.Append
                     (To_Unbounded_String (Safe_Name (Nam, "COL" & Idx)));
               end;
            end loop;
            Free (Cells);
         end Collect_OOXML_Headers;

         procedure Infer_And_Create_OOXML_Schema
            (Col_Name_Vec : Name_Vecs.Vector;
             Row1_Present : Boolean;
             Row1         : DOM.Core.Node) is
            N         : constant Natural := Natural (Col_Name_Vec.Length);
            Col_Types : Column_Type_Array (1 .. N) := (others => Col_Numeric);
         begin
            Apply_Name_Suffix_Types (Col_Name_Vec, Col_Types);
            if Row1_Present then
               declare
                  Data_Cells : DOM.Core.Node_List :=
                     Get_Elements_By_Tag_Name (DOM.Core.Element (Row1), "c");
                  Col_Idx : Natural := 0;
               begin
                  for J in 0 .. Length (Data_Cells) - 1 loop
                     Col_Idx := Col_Idx + 1;
                     exit when Col_Idx > N;
                     if Col_Types (Col_Idx) /= Col_Integer
                        and then Get_Cell_Value (Item (Data_Cells, J)).Kind
                                 = Val_String
                     then
                        Col_Types (Col_Idx) := Col_String;
                     end if;
                  end loop;
                  Free (Data_Cells);
               end;
            end if;
            for I in 1 .. N loop
               declare
                  Raw_Name   : constant String := To_String (Col_Name_Vec (I));
                  Final_Name : constant String :=
                     (if Col_Types (I) = Col_String
                         and then (Raw_Name'Length = 0
                                   or else Raw_Name (Raw_Name'Last) /= '$')
                      then Raw_Name & "$"
                      else Raw_Name);
               begin
                  Add_Column (Final_Name, Col_Types (I));
               end;
            end loop;
         end Infer_And_Create_OOXML_Schema;

         procedure Load_OOXML_Data_Rows
            (Rows      : DOM.Core.Node_List;
             Col_Count : Natural) is
            Rows_To_Skip : Natural := Skip_Rows;
            Rows_Written : Natural := 0;
         begin
            for I in 1 .. Length (Rows) - 1 loop
               exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
               if Rows_To_Skip > 0 then
                  Rows_To_Skip := Rows_To_Skip - 1;
               else
                  Rows_Written := Rows_Written + 1;
                  Add_Row;
                  SData_Core.IO.Show_Progress ("USE", Rows_Written);
                  declare
                     Cells : DOM.Core.Node_List :=
                        Get_Elements_By_Tag_Name
                           (DOM.Core.Element (Item (Rows, I)), "c");
                  begin
                     for J in 0 .. Length (Cells) - 1 loop
                        if J < Col_Count then
                           declare
                              V : constant Value :=
                                 Get_Cell_Value (Item (Cells, J));
                           begin
                              if V.Kind = Val_Numeric
                                 and then Get_Column_Type
                                    (Column_Name (J + 1)) = Col_Integer
                                 and then V.Num_Val
                                    /= Float'Truncation (V.Num_Val)
                                 and then
                                    not SData_Core.Config.Quiet_Mode
                              then
                                 Put_Line_Error
                                    ("Warning: OOXML import, row" &
                                     Row_Count'Image &
                                     ", column """ &
                                     Column_Name (J + 1) &
                                     """: non-integer value truncated");
                              end if;
                              if V.Kind /= Val_Missing then
                                 Set_Value (Row_Count, Column_Name (J + 1), V);
                              end if;
                           exception
                              when E : others =>
                                 if not SData_Core.Config.Quiet_Mode then
                                    Put_Line_Error
                                       ("Warning: OOXML import skipped cell at row" &
                                        Row_Count'Image &
                                        ", column """ &
                                        Column_Name (J + 1) & """: " &
                                        Ada.Exceptions.Exception_Message (E));
                                 end if;
                           end;
                        end if;
                     end loop;
                     Free (Cells);
                  end;
               end if;
            end loop;
         end Load_OOXML_Data_Rows;

      begin
         UnZip.Extract (from => Zip_Info, what => Sheet_XML_Path,
                        rename => Temp_Sheet);

         if Has_Formulas_XML (Temp_Sheet, Is_ODF => False) then
            declare
               Converted : constant String :=
                  Convert_Via_LibreOffice (File_Name, SData_Core.Config.OOXML);
               OK : Boolean;
            begin
               if Converted /= "" then
                  GNAT.OS_Lib.Delete_File (Temp_Sheet, OK);
                  DOM.Readers.Free (Reader);
                  SData_Core.File_IO.ODF.Parse_ODF (Converted);
                  GNAT.OS_Lib.Delete_File (Converted, OK);
                  return;
               end if;
               if not SData_Core.Config.Quiet_Mode then
                  Put_Line_Error
                     ("Warning: formula cells found in XLSX file but LibreOffice " &
                      "is not available; using cached values.");
               end if;
            end;
         end if;

         Input_Sources.File.Open (Temp_Sheet, Input);
         DOM.Readers.Parse (Reader, Input);
         Doc := DOM.Readers.Get_Tree (Reader);
         Input_Sources.File.Close (Input);

         declare
            Merged : DOM.Core.Node_List :=
               DOM.Core.Documents.Get_Elements_By_Tag_Name (Doc, "mergeCells");
         begin
            if Length (Merged) > 0 then
               Free (Merged);
               DOM.Readers.Free (Reader);
               raise SData_Core.Script_Error
                  with "XLSX file contains merged cells, which are not supported.";
            end if;
            Free (Merged);
         end;

         Rows := DOM.Core.Documents.Get_Elements_By_Tag_Name (Doc, "row");
         Clear;

         if Length (Rows) > 0 then
            declare
               Col_Name_Vec : Name_Vecs.Vector;
            begin
               Collect_OOXML_Headers (Item (Rows, 0), Col_Name_Vec);
               Infer_And_Create_OOXML_Schema
                  (Col_Name_Vec,
                   Row1_Present => Length (Rows) > 1,
                   Row1         => Item (Rows, 1));
               Load_OOXML_Data_Rows (Rows, Col_Count => Column_Count);
            end;
         end if;

         Free (Rows);
         DOM.Readers.Free (Reader);
         GNAT.OS_Lib.Delete_File (Temp_Sheet, Success);
      exception
         when others =>
            DOM.Readers.Free (Reader);
            raise;
      end Load_Sheet;

      Zip_Info : Zip.Zip_Info;
   begin
      Zip.Load (Zip_Info, File_Name);
      Load_Shared_Strings (Zip_Info);
      declare
         Sheet_Path : constant String := Find_Sheet_XML_Path (Zip_Info);
      begin
         Load_Sheet (Zip_Info, Sheet_Path);
      end;
   exception
      when E : others =>
         declare OK : Boolean; begin
            if GNAT.OS_Lib.Is_Regular_File (Temp_Shared) then
               GNAT.OS_Lib.Delete_File (Temp_Shared, OK);
            end if;
            if GNAT.OS_Lib.Is_Regular_File (Temp_Sheet) then
               GNAT.OS_Lib.Delete_File (Temp_Sheet, OK);
            end if;
            if GNAT.OS_Lib.Is_Regular_File (Temp_Workbook) then
               GNAT.OS_Lib.Delete_File (Temp_Workbook, OK);
            end if;
            if GNAT.OS_Lib.Is_Regular_File (Temp_Rels) then
               GNAT.OS_Lib.Delete_File (Temp_Rels, OK);
            end if;
         end;
         raise SData_Core.Script_Error with
            "Failed to parse OOXML file """ & File_Name & """: " &
            Ada.Exceptions.Exception_Message (E);
   end Parse_OOXML;

   -----------------
   -- Write_OOXML --
   -----------------
   procedure Write_OOXML (File_Name : String; Sheet_Name : String := "Sheet1") is
      use Zip.Create;
      Info          : Zip_Create_Info;
      Z_File_Stream : aliased Zip_File_Stream;
      N             : constant Natural := Column_Count;
      Sname         : constant String  :=
         (if Sheet_Name = "" then "Sheet1" else Sheet_Name);
   begin
      if N = 0 then return; end if;

      Create_Archive (Info, Z_File_Stream'Unchecked_Access, File_Name);

      Add_String (Info,
         "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>" &
         "<Types xmlns=""http://schemas.openxmlformats.org/package/2006/content-types"">" &
         "<Default Extension=""rels"" ContentType=""application/vnd.openxmlformats-package.relationships+xml""/>" &
         "<Default Extension=""xml"" ContentType=""application/xml""/>" &
         "<Override PartName=""/xl/workbook.xml"" ContentType=""application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml""/>" &
         "<Override PartName=""/xl/worksheets/sheet1.xml"" ContentType=""application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml""/>" &
         "</Types>",
         "[Content_Types].xml");

      Add_String (Info,
         "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>" &
         "<Relationships xmlns=""http://schemas.openxmlformats.org/package/2006/relationships"">" &
         "<Relationship Id=""rId1"" Type=""http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"" Target=""xl/workbook.xml""/>" &
         "</Relationships>",
         "_rels/.rels");

      Add_String (Info,
         "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>" &
         "<workbook xmlns=""http://schemas.openxmlformats.org/spreadsheetml/2006/main"" xmlns:r=""http://schemas.openxmlformats.org/officeDocument/2006/relationships"">" &
         "<sheets><sheet name=""" & Escape_XML (Sname) &
         """ sheetId=""1"" r:id=""rId1""/></sheets>" &
         "</workbook>",
         "xl/workbook.xml");

      Add_String (Info,
         "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>" &
         "<Relationships xmlns=""http://schemas.openxmlformats.org/package/2006/relationships"">" &
         "<Relationship Id=""rId1"" Type=""http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"" Target=""worksheets/sheet1.xml""/>" &
         "</Relationships>",
         "xl/_rels/workbook.xml.rels");

      declare
         S1 : Unbounded_String;
      begin
         Append (S1,
            "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>" &
            ASCII.LF);
         Append (S1,
            "<worksheet xmlns=""http://schemas.openxmlformats.org/spreadsheetml/2006/main"">" &
            ASCII.LF);
         Append (S1, "<sheetData>" & ASCII.LF);

         Append (S1, "<row r=""1"">");
         for C in 1 .. N loop
            declare
               Ref : constant String := Col_To_Letters (C) & "1";
               Val : constant String := Escape_XML (Column_Name (C));
            begin
               Append (S1,
                  "<c r=""" & Ref & """ t=""inlineStr""><is><t>" &
                  Val & "</t></is></c>");
            end;
         end loop;
         Append (S1, "</row>" & ASCII.LF);

         for R in 1 .. Row_Count loop
            SData_Core.IO.Show_Progress ("SAVE", R);
            Append (S1,
               "<row r=""" & Trim (Integer (R + 1)'Img, Ada.Strings.Both) &
               """>");
            for C in 1 .. N loop
               declare
                  Ref : constant String :=
                     Col_To_Letters (C) &
                     Trim (Integer (R + 1)'Img, Ada.Strings.Both);
                  V   : constant Value := Get_Value (R, Column_Name (C));
               begin
                  case V.Kind is
                     when Val_Numeric =>
                        if Is_Inf (V.Num_Val) then
                           declare
                              Img : constant String :=
                                 (if V.Num_Val > 0.0 then "Inf" else "-Inf");
                           begin
                              Append (S1,
                                 "<c r=""" & Ref &
                                 """ t=""inlineStr""><is><t>" &
                                 Img & "</t></is></c>");
                           end;
                        else
                           Append (S1,
                              "<c r=""" & Ref & """><v>" &
                              Trim (V.Num_Val'Img, Ada.Strings.Both) &
                              "</v></c>");
                        end if;
                     when Val_Integer =>
                        Append (S1,
                           "<c r=""" & Ref & """><v>" &
                           Trim (V.Int_Val'Img, Ada.Strings.Both) &
                           "</v></c>");
                     when Val_String =>
                        Append (S1,
                           "<c r=""" & Ref &
                           """ t=""inlineStr""><is><t>" &
                           Escape_XML (SData_Core.Values.To_String (V)) &
                           "</t></is></c>");
                     when Val_Missing =>
                        null;
                  end case;
               end;
            end loop;
            Append (S1, "</row>" & ASCII.LF);
         end loop;
         SData_Core.IO.Show_Progress ("SAVE", Row_Count, Final => True);

         Append (S1, "</sheetData>" & ASCII.LF);
         Append (S1, "</worksheet>");
         Add_String (Info, S1, "xl/worksheets/sheet1.xml");
      end;

      Finish (Info);
   end Write_OOXML;

end SData_Core.File_IO.OOXML;