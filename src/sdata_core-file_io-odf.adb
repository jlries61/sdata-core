--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

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
with Input_Sources.File;
with SData_Core.Config;
with SData_Core.File_IO.Helpers;   use SData_Core.File_IO.Helpers;
with SData_Core.File_IO.OOXML;

package body SData_Core.File_IO.ODF is

   --  DOM traversal note: XML-Ada does not include an XPath engine.  All element
   --  lookups use Get_Elements_By_Tag_Name / Get_Elements_By_Tag_Name_NS and
   --  attribute accessors from DOM.Core.Elements.

   procedure Parse_ODF (File_Name  : String;
                        Sheet_Name : String  := "";
                        Skip_Rows  : Natural := 0;
                        Max_Rows   : Natural := 0) is
      use DOM.Core;
      use DOM.Core.Nodes;
      use DOM.Core.Elements;

      Temp_XML : constant String := File_Name & ".content.xml";

      procedure Load_Content (Zip_Info : Zip.Zip_Info) is
         Reader : Secure_Reader;
         Input  : Input_Sources.File.File_Input;
         Doc    : DOM.Core.Document;
         Tables, Rows : Node_List;
         Success : Boolean;

         function Get_Cell_Value
            (Cell_Node   : Node;
             Target_Type : Column_Type := Col_Numeric) return Value
         is
            Val_Type : constant String :=
               Get_Attribute (DOM.Core.Element (Cell_Node), "office:value-type");
            P_List   : Node_List :=
               Get_Elements_By_Tag_Name (DOM.Core.Element (Cell_Node), "text:p");
         begin
            if Val_Type = "float" or else Val_Type = "currency"
               or else Val_Type = "percentage"
            then
               declare
                  V_Attr : constant String :=
                     Get_Attribute (DOM.Core.Element (Cell_Node), "office:value");
               begin
                  --  A numeric cell destined for a '$' (character) column is
                  --  stored as its displayed text rather than dropped: prefer
                  --  the text:p rendering, falling back to office:value.
                  if Target_Type = Col_String then
                     declare
                        S : constant String :=
                           (if Length (P_List) > 0
                            then Get_Text (Item (P_List, 0)) else V_Attr);
                     begin
                        Free (P_List);
                        return (Kind => Val_String,
                                Str_Val => To_Unbounded_String (S));
                     end;
                  end if;
                  Free (P_List);
                  begin
                     return (Kind => Val_Numeric, Num_Val => Float'Value (V_Attr));
                  exception
                     when Constraint_Error => return (Kind => Val_Missing);
                  end;
               end;
            elsif Length (P_List) > 0 then
               declare
                  S   : constant String := Get_Text (Item (P_List, 0));
                  Inf : constant Value  := Detect_Inf (S);
               begin
                  Free (P_List);
                  if Inf.Kind /= Val_Missing then return Inf; end if;
                  return (Kind => Val_String, Str_Val => To_Unbounded_String (S));
               end;
            end if;
            Free (P_List);
            return (Kind => Val_Missing);
         end Get_Cell_Value;

         procedure Collect_ODF_Headers
            (Row0         : DOM.Core.Node;
             Col_Name_Vec : in out Name_Vecs.Vector) is
            Cells : DOM.Core.Node_List :=
               Get_Elements_By_Tag_Name
                  (DOM.Core.Element (Row0), "table:table-cell");
         begin
            for I in 0 .. Length (Cells) - 1 loop
               declare
                  Cell        : constant DOM.Core.Node := Item (Cells, I);
                  Col_Spanned : constant String :=
                     Get_Attribute (DOM.Core.Element (Cell),
                                    "table:number-columns-spanned");
                  Row_Spanned : constant String :=
                     Get_Attribute (DOM.Core.Element (Cell),
                                    "table:number-rows-spanned");
               begin
                  if (Col_Spanned /= "" and then Positive'Value (Col_Spanned) > 1)
                     or else
                     (Row_Spanned /= "" and then Positive'Value (Row_Spanned) > 1)
                  then
                     Free (Cells);
                     raise SData_Core.Script_Error
                        with "ODS file contains merged cells, which are not supported.";
                  end if;
                  declare
                     Repeat_Attr  : constant String :=
                        Get_Attribute (DOM.Core.Element (Cell),
                                       "table:number-columns-repeated");
                     Repeat_Count : constant Positive :=
                        (if Repeat_Attr = "" then 1
                         else Positive'Value (Repeat_Attr));
                     P_Nodes      : DOM.Core.Node_List :=
                        Get_Elements_By_Tag_Name
                           (DOM.Core.Element (Cell), "text:p");
                     Base_Name    : constant String :=
                        (if Length (P_Nodes) > 0
                         then Get_Text (Item (P_Nodes, 0))
                         else "");
                  begin
                     Free (P_Nodes);
                     for K in 1 .. Repeat_Count loop
                        exit when Base_Name = "" and then K > 1;
                        declare
                           Idx_Num    : constant Natural :=
                              Natural (Col_Name_Vec.Length) + 1;
                           Idx        : constant String :=
                              Trim (Idx_Num'Img, Ada.Strings.Both);
                           Final_Name : constant String :=
                              (if Base_Name = "" then "COL" & Idx
                               else Base_Name &
                                  (if Repeat_Count > 1
                                   then "_" & Trim (K'Img, Ada.Strings.Both)
                                   else ""));
                        begin
                           Col_Name_Vec.Append
                              (To_Unbounded_String
                                 (Safe_Name (Final_Name, "COL" & Idx)));
                        end;
                     end loop;
                  end;
               end;
            end loop;
            Free (Cells);
         end Collect_ODF_Headers;

         procedure Infer_And_Create_ODF_Schema
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
                     Get_Elements_By_Tag_Name
                        (DOM.Core.Element (Row1), "table:table-cell");
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
         end Infer_And_Create_ODF_Schema;

         procedure Load_ODF_Data_Rows
            (Rows      : DOM.Core.Node_List;
             Col_Count : Natural) is
            Rows_To_Skip : Natural := Skip_Rows;
            Rows_Written : Natural := 0;
         begin
            for I in 1 .. Length (Rows) - 1 loop
               declare
                  Row_Node         : constant DOM.Core.Node := Item (Rows, I);
                  Row_Repeat_Attr  : constant String :=
                     Get_Attribute (DOM.Core.Element (Row_Node),
                                    "table:number-rows-repeated");
                  Row_Repeat_Count : constant Positive :=
                     (if Row_Repeat_Attr = "" then 1
                      else Positive'Value (Row_Repeat_Attr));
               begin
                  exit when Row_Repeat_Count > 1000;
                  exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
                  for R_Count in 1 .. Row_Repeat_Count loop
                     pragma Warnings (Off, R_Count);
                     if Rows_To_Skip > 0 then
                        Rows_To_Skip := Rows_To_Skip - 1;
                     else
                        exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
                        Rows_Written := Rows_Written + 1;
                        Add_Row;
                        SData_Core.IO.Show_Progress ("USE", Rows_Written);
                        declare
                           Cells   : DOM.Core.Node_List :=
                              Get_Elements_By_Tag_Name
                                 (DOM.Core.Element (Row_Node),
                                  "table:table-cell");
                           Col_Idx : Positive := 1;
                        begin
                           for J in 0 .. Length (Cells) - 1 loop
                              declare
                                 Cell         : constant DOM.Core.Node :=
                                    Item (Cells, J);
                                 Repeat_Attr  : constant String :=
                                    Get_Attribute (DOM.Core.Element (Cell),
                                                   "table:number-columns-repeated");
                                 Repeat_Count : constant Positive :=
                                    (if Repeat_Attr = "" then 1
                                     else Positive'Value (Repeat_Attr));
                                 Val : constant Value :=
                                    Get_Cell_Value
                                       (Cell,
                                        (if Col_Idx <= Col_Count
                                         then Get_Column_Type
                                                 (Column_Name (Col_Idx))
                                         else Col_Numeric));
                              begin
                                 for K in 1 .. Repeat_Count loop
                                    pragma Warnings (Off, K);
                                    if Col_Idx <= Col_Count then
                                       if Val.Kind = Val_Numeric
                                          and then Get_Column_Type
                                             (Column_Name (Col_Idx))
                                             = Col_Integer
                                          and then Val.Num_Val
                                             /= Float'Truncation (Val.Num_Val)
                                          and then
                                             not SData_Core.Config.Quiet_Mode
                                       then
                                          Put_Line_Error
                                             ("Warning: ODF import, row" &
                                              Row_Count'Image &
                                              ", column """ &
                                              Column_Name (Col_Idx) &
                                              """: non-integer value" &
                                              " truncated");
                                       end if;
                                       if Val.Kind /= Val_Missing then
                                          begin
                                             Set_Value (Row_Count,
                                                        Column_Name (Col_Idx),
                                                        Val);
                                          exception
                                             when E : others =>
                                                if not SData_Core.Config.Quiet_Mode then
                                                   Put_Line_Error
                                                      ("Warning: ODF import skipped " &
                                                       "cell at row" &
                                                       Row_Count'Image &
                                                       ", column """ &
                                                       Column_Name (Col_Idx) &
                                                       """: " &
                                                       Ada.Exceptions.Exception_Message (E));
                                                end if;
                                          end;
                                       end if;
                                       Col_Idx := Col_Idx + 1;
                                    end if;
                                 end loop;
                              end;
                              exit when Col_Idx > Col_Count;
                           end loop;
                           Free (Cells);
                        end;
                     end if;
                  end loop;
               end;
            end loop;
         end Load_ODF_Data_Rows;

      begin
         UnZip.Extract (from => Zip_Info, what => "content.xml", rename => Temp_XML);

         if Has_Formulas_XML (Temp_XML, Is_ODF => True) then
            declare
               Converted : constant String :=
                  Convert_Via_LibreOffice (File_Name, SData_Core.Config.ODF);
               OK : Boolean;
            begin
               if Converted /= "" then
                  GNAT.OS_Lib.Delete_File (Temp_XML, OK);
                  Free (Reader);
                  SData_Core.File_IO.OOXML.Parse_OOXML (Converted);
                  GNAT.OS_Lib.Delete_File (Converted, OK);
                  return;
               end if;
               if not SData_Core.Config.Quiet_Mode then
                  Put_Line_Error
                     ("Warning: formula cells found in ODS file but LibreOffice " &
                      "is not available; using cached values.");
               end if;
            end;
         end if;

         Input_Sources.File.Open (Temp_XML, Input);
         Parse (Reader, Input);
         Doc := Get_Tree (Reader);
         Input_Sources.File.Close (Input);

         Tables := DOM.Core.Documents.Get_Elements_By_Tag_Name (Doc, "table:table");
         if Length (Tables) = 0 then
            Free (Tables); Free (Reader);
            raise SData_Core.Script_Error with "No tables found in ODS file";
         end if;

         declare
            Target_Idx : Natural := 0;
         begin
            if Sheet_Name /= "" then
               for T in 0 .. Length (Tables) - 1 loop
                  if Get_Attribute (DOM.Core.Element (Item (Tables, T)),
                                    "table:name") = Sheet_Name
                  then
                     Target_Idx := T;
                     exit;
                  end if;
               end loop;
            end if;
            Rows := Get_Elements_By_Tag_Name
               (DOM.Core.Element (Item (Tables, Target_Idx)), "table:table-row");
         end;
         Clear;

         if Length (Rows) > 0 then
            declare
               Col_Name_Vec : Name_Vecs.Vector;
            begin
               Collect_ODF_Headers (Item (Rows, 0), Col_Name_Vec);
               Infer_And_Create_ODF_Schema
                  (Col_Name_Vec,
                   Row1_Present => Length (Rows) > 1,
                   Row1         => Item (Rows, 1));
               Load_ODF_Data_Rows (Rows, Col_Count => Column_Count);
            end;
         end if;

         Free (Rows);
         Free (Tables);
         Free (Reader);
         GNAT.OS_Lib.Delete_File (Temp_XML, Success);
      exception
         when others =>
            Free (Reader);
            raise;
      end Load_Content;

      Zip_Info : Zip.Zip_Info;
   begin
      Zip.Load (Zip_Info, File_Name);
      Load_Content (Zip_Info);
   exception
      when E : others =>
         if GNAT.OS_Lib.Is_Regular_File (Temp_XML) then
            declare OK : Boolean;
            begin GNAT.OS_Lib.Delete_File (Temp_XML, OK); end;
         end if;
         raise SData_Core.Script_Error with
            "Failed to parse ODS file """ & File_Name & """: " &
            Ada.Exceptions.Exception_Message (E);
   end Parse_ODF;

   ---------------
   -- Write_ODF --
   ---------------
   procedure Write_ODF (File_Name : String; Sheet_Name : String := "Sheet1";
                        Decimals  : Integer := -1) is
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
         "application/vnd.oasis.opendocument.spreadsheet", "mimetype");

      Add_String (Info,
         "<?xml version=""1.0"" encoding=""UTF-8""?>" &
         "<manifest:manifest xmlns:manifest=""urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"" manifest:version=""1.2"">" &
         "<manifest:file-entry manifest:full-path=""/"" manifest:version=""1.2"" manifest:media-type=""application/vnd.oasis.opendocument.spreadsheet""/>" &
         "<manifest:file-entry manifest:full-path=""content.xml"" manifest:media-type=""text/xml""/>" &
         "</manifest:manifest>",
         "META-INF/manifest.xml");

      declare
         S1 : Unbounded_String;
      begin
         Append (S1, "<?xml version=""1.0"" encoding=""UTF-8""?>" & ASCII.LF);
         --  Common root prefix; the datastyle/style namespaces and the
         --  automatic-styles block are added only when /DECIMALS is set.
         Append (S1,
            "<office:document-content xmlns:office=""urn:oasis:names:tc:opendocument:xmlns:office:1.0"" " &
            "xmlns:table=""urn:oasis:names:tc:opendocument:xmlns:table:1.0"" " &
            "xmlns:text=""urn:oasis:names:tc:opendocument:xmlns:text:1.0"" ");
         if Decimals >= 0 then
            Append (S1,
               "xmlns:number=""urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"" " &
               "xmlns:style=""urn:oasis:names:tc:opendocument:xmlns:style:1.0"" ");
         end if;
         Append (S1, "office:version=""1.2"">" & ASCII.LF);
         if Decimals >= 0 then
            declare
               DP : constant String := Trim (Decimals'Img, Ada.Strings.Both);
            begin
               Append (S1,
                  "<office:automatic-styles>" &
                  "<number:number-style style:name=""NDEC"">" &
                  "<number:number number:decimal-places=""" & DP &
                  """ number:min-decimal-places=""" & DP & """/>" &
                  "</number:number-style>" &
                  "<style:style style:name=""ceDEC"" style:family=""table-cell"" " &
                  "style:data-style-name=""NDEC""/>" &
                  "</office:automatic-styles>" & ASCII.LF);
            end;
         end if;
         Append (S1, "<office:body><office:spreadsheet>" & ASCII.LF);
         Append (S1, "<table:table table:name=""" & Escape_XML (Sname) & """>" & ASCII.LF);

         Append (S1, "<table:table-row>");
         for C in 1 .. N loop
            Append (S1,
               "<table:table-cell office:value-type=""string""><text:p>" &
               Escape_XML (Column_Name (C)) & "</text:p></table:table-cell>");
         end loop;
         Append (S1, "</table:table-row>" & ASCII.LF);

         --  Iterate the logical (post-SELECT) view; identity when unfiltered.
         for L in 1 .. Logical_Row_Count loop
            SData_Core.IO.Show_Progress ("SAVE", L);
            Append (S1, "<table:table-row>");
            for C in 1 .. N loop
               declare
                  R : constant Positive := Logical_To_Physical (L);
                  V : constant Value := Get_Value (R, Column_Name (C));
               begin
                  case V.Kind is
                     when Val_Numeric =>
                        if Is_Inf (V.Num_Val) then
                           declare
                              Img : constant String :=
                                 (if V.Num_Val > 0.0 then "Inf" else "-Inf");
                           begin
                              Append (S1,
                                 "<table:table-cell office:value-type=""string"">" &
                                 "<text:p>" & Img & "</text:p></table:table-cell>");
                           end;
                        else
                           declare
                              RT   : constant String :=
                                 SData_Core.Values.Image_Round_Trip (V.Num_Val);
                              Disp : constant String :=
                                 (if Decimals >= 0
                                  then SData_Core.Values.Image_Fixed_Decimals
                                          (V.Num_Val, Decimals)
                                  else RT);
                              Sty  : constant String :=
                                 (if Decimals >= 0
                                  then " table:style-name=""ceDEC""" else "");
                           begin
                              Append (S1,
                                 "<table:table-cell" & Sty &
                                 " office:value-type=""float"" office:value=""" &
                                 RT & """>" &
                                 "<text:p>" & Disp &
                                 "</text:p></table:table-cell>");
                           end;
                        end if;
                     when Val_Integer =>
                        Append (S1,
                           "<table:table-cell office:value-type=""float"" office:value=""" &
                           Trim (V.Int_Val'Img, Ada.Strings.Both) & """>" &
                           "<text:p>" & Trim (V.Int_Val'Img, Ada.Strings.Both) &
                           "</text:p></table:table-cell>");
                     when Val_String =>
                        Append (S1,
                           "<table:table-cell office:value-type=""string""><text:p>" &
                           Escape_XML (SData_Core.Values.To_String (V)) &
                           "</text:p></table:table-cell>");
                     when Val_Missing =>
                        Append (S1, "<table:table-cell/>");
                  end case;
               end;
            end loop;
            Append (S1, "</table:table-row>" & ASCII.LF);
         end loop;
         SData_Core.IO.Show_Progress ("SAVE", Logical_Row_Count, Final => True);

         Append (S1,
            "</table:table></office:spreadsheet></office:body></office:document-content>");
         Add_String (Info, S1, "content.xml");
      end;

      Finish (Info);
   end Write_ODF;

end SData_Core.File_IO.ODF;