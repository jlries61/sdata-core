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

   procedure Parse_ODF (File_Name      : String;
                        Sheet_Name     : String  := "";
                        Skip_Rows      : Natural := 0;
                        Max_Rows       : Natural := 0;
                        Declared_Types : String  := "") is
      use DOM.Core;
      use DOM.Core.Nodes;
      use DOM.Core.Elements;

      Temp_XML : constant String := File_Name & ".content.xml";

      --  ADR-084 / ADR-0027: /TYPES= declarations, parsed once per call.
      Declared_List : Declared_Vecs.Vector;

      --  ADR-0020 parity (ADR-0027, "Warning parity"): a declared numeric
      --  column over text cells coerces to missing, and those warnings are
      --  capped exactly as CSV's are -- same counter shape, same cap, same
      --  message wording -- so the user-visible rule really is one rule
      --  across all three formats rather than a CSV rule and a spreadsheet
      --  carve-out.  Before this, the spreadsheet path warned once per cell,
      --  uncapped.
      Coercion_Warn_Count : Natural := 0;
      Coercion_Warn_Cap   : constant := 10;
      Q : constant Character := '"';

      procedure Load_Content (Zip_Info : Zip.Zip_Info) is
         Reader : Secure_Reader;
         Input  : Input_Sources.File.File_Input;
         Doc    : DOM.Core.Document;
         Tables, Rows : Node_List;
         Success : Boolean;

         --  Col_Name/Row_No are supplied only by the DATA-LOADING call site,
         --  so the schema-inference call never warns (inference is not a
         --  coercion).  When present they let a failed string->number parse
         --  report itself in exactly CSV's words, under ADR-0020's cap.
         function Get_Cell_Value
            (Cell_Node   : Node;
             Target_Type : Column_Type := Col_Numeric;
             Col_Name    : String      := "";
             Row_No      : Natural     := 0;
             --  Coercion is OPT-IN, and only the data-loading call site opts
             --  in.  The schema-inference probe and (OOXML) the header
             --  collector call this to ask what a cell NATURALLY is; if a
             --  string cell were parsed as a number for them, inference would
             --  never see Val_String and a text column would come out numeric.
             --  Defaulting to False keeps every non-loading caller on exactly
             --  its pre-existing behavior.
             Coerce_To_Target : Boolean := False) return Value
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
                     return (Kind => Val_Numeric, Num_Val => Real'Value (V_Attr));
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
                  --  ADR-0027 ("Get_Cell_Value honors Target_Type on its
                  --  string-producing paths"): a string cell destined for a
                  --  NUMERIC column is parsed as a number, falling back to
                  --  missing -- the same shape the numeric branch above
                  --  already uses for the opposite direction.  Without this
                  --  the cell would return Val_String into a Col_Numeric
                  --  column and Coerce_Value would raise
                  --  Type_Mismatch_Error, which /TYPES= would then surface
                  --  as a per-cell "import skipped" warning instead of the
                  --  documented coerce-to-missing.
                  --
                  --  The Inf check therefore lives INSIDE this dispatch, not
                  --  in front of it.  Returning Inf before it ignored
                  --  Target_Type, so an "Inf" cell in a column declared
                  --  CHARACTER produced numeric infinity into a Col_String
                  --  column, Coerce_Value raised, and the generic handler
                  --  dropped the value with an uncapped legacy warning --
                  --  the very defect this section exists to remove,
                  --  surviving on the one path the first fix did not sweep.
                  if Target_Type = Col_String then
                     --  Character target: store the text, Inf included.
                     return (Kind => Val_String,
                             Str_Val => To_Unbounded_String (S));
                  end if;
                  if Inf.Kind /= Val_Missing then return Inf; end if;
                  if Coerce_To_Target
                     and then (Target_Type = Col_Numeric
                               or else Target_Type = Col_Integer)
                  then
                     begin
                        return (Kind => Val_Numeric, Num_Val => Real'Value (S));
                     exception
                        when Constraint_Error =>
                           --  ADR-0027 ("Warning parity"): same counter, same
                           --  cap, same wording as the CSV reader's coercion
                           --  warning (ADR-0020), so one documented rule
                           --  covers all three formats instead of a
                           --  spreadsheet carve-out.
                           if Col_Name /= "" then
                              Coercion_Warn_Count := Coercion_Warn_Count + 1;
                              if Coercion_Warn_Count <= Coercion_Warn_Cap then
                                 SData_Core.IO.Put_Line_Error
                                    ("Warning: " & Q & File_Name & Q &
                                     ", data row" & Natural'Image (Row_No) &
                                     ", column " & Q & Col_Name & Q &
                                     ": non-numeric value " & Q & S & Q &
                                     " in " &
                                     (if Target_Type = Col_Integer
                                      then "integer" else "numeric") &
                                     " column -- stored as missing");
                              end if;
                           end if;
                           return (Kind => Val_Missing);
                     end;
                  end if;
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
             Row1         : DOM.Core.Node;
             Final_Names  : out Name_Vecs.Vector) is
            N         : constant Natural := Natural (Col_Name_Vec.Length);
            Col_Types : Column_Type_Array (1 .. N) := (others => Col_Numeric);
            --  ADR-0027 ("A lock array in ODF and OOXML"): ODF had no
            --  equivalent of CSV's Col_Determined, so without this a
            --  declared-float column would be silently re-inferred to
            --  character by row 1 and the declaration would appear to do
            --  nothing.
            Col_Locked : Lock_Array (1 .. N) := (others => False);
            Seen      : Name_Vecs.Vector;
         begin
            Apply_Name_Suffix_Types (Col_Name_Vec, Col_Types);
            Apply_Declared_Types
               (Declared_List, Col_Name_Vec, Col_Types, Col_Locked, File_Name);
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
                     if not Col_Locked (Col_Idx)
                        and then Col_Types (Col_Idx) /= Col_Integer
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
                  --  ADR-084: one shared naming rule (see Final_Column_Name).
                  --  Behavior-identical for every pre-existing input; also
                  --  handles the demoted case only /TYPES= can create.
                  Final_Name : constant String :=
                     Final_Column_Name (Raw_Name, Col_Types (I));
               begin
                  Warn_If_Duplicate_Name (File_Name, Final_Name, Seen);
                  Add_Column (Final_Name, Col_Types (I));
                  Final_Names.Append (To_Unbounded_String (Final_Name));
               end;
            end loop;
         end Infer_And_Create_ODF_Schema;

         procedure Load_ODF_Data_Rows
            (Rows      : DOM.Core.Node_List;
             Col_Names : Name_Vecs.Vector) is
            Rows_To_Skip : Natural := Skip_Rows;
            Rows_Written : Natural := 0;
            --  ADR-0018 amendment: the RAW per-cell-position decorated name
            --  list (one entry per original header column, duplicates
            --  included) -- see Load_OOXML_Data_Rows's matching comment for
            --  why this replaces the physical (deduplicated) column count.
            N_Cols       : constant Natural := Natural (Col_Names.Length);
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
                                        (if Col_Idx <= N_Cols
                                         then Get_Column_Type
                                                 (To_String (Col_Names (Col_Idx)))
                                         else Col_Numeric),
                                        Col_Name =>
                                           (if Col_Idx <= N_Cols
                                            then To_String (Col_Names (Col_Idx))
                                            else ""),
                                        Row_No   => Rows_Written,
                                        Coerce_To_Target => True);
                              begin
                                 for K in 1 .. Repeat_Count loop
                                    pragma Warnings (Off, K);
                                    if Col_Idx <= N_Cols then
                                       if Val.Kind = Val_Numeric
                                          and then Get_Column_Type
                                             (To_String (Col_Names (Col_Idx)))
                                             = Col_Integer
                                          and then Val.Num_Val
                                             /= Real'Truncation (Val.Num_Val)
                                       then
                                          Put_Line_Error
                                             ("Warning: ODF import, row" &
                                              Row_Count'Image &
                                              ", column """ &
                                              To_String (Col_Names (Col_Idx)) &
                                              """: non-integer value" &
                                              " truncated");
                                       end if;
                                       if Val.Kind /= Val_Missing then
                                          begin
                                             Set_Value (Row_Count,
                                                        To_String (Col_Names (Col_Idx)),
                                                        Val);
                                          exception
                                             when E : others =>
                                                Put_Line_Error
                                                   ("Warning: ODF import skipped " &
                                                    "cell at row" &
                                                    Row_Count'Image &
                                                    ", column """ &
                                                    To_String (Col_Names (Col_Idx)) &
                                                    """: " &
                                                    Ada.Exceptions.Exception_Message (E));
                                          end;
                                       end if;
                                       Col_Idx := Col_Idx + 1;
                                    end if;
                                 end loop;
                              end;
                              exit when Col_Idx > N_Cols;
                           end loop;
                           Free (Cells);
                        end;
                     end if;
                  end loop;
               end;
            end loop;
            --  ADR-0020's suppression summary, in CSV's own words
            --  (ADR-0027, "Warning parity").
            if Coercion_Warn_Count > Coercion_Warn_Cap then
               SData_Core.IO.Put_Line_Error
                  ("Warning: " & Q & File_Name & Q & ":" &
                   Natural'Image (Coercion_Warn_Count - Coercion_Warn_Cap) &
                   " additional non-numeric-value warning(s) suppressed (" &
                   Trim (Natural'Image (Coercion_Warn_Cap), Ada.Strings.Left) &
                   " shown," & Natural'Image (Coercion_Warn_Count) & " total)");
            end if;
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
               Put_Line_Error
                  ("Warning: formula cells found in ODS file but LibreOffice " &
                   "is not available; using cached values.");
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
               Final_Names  : Name_Vecs.Vector;
            begin
               Collect_ODF_Headers (Item (Rows, 0), Col_Name_Vec);
               Infer_And_Create_ODF_Schema
                  (Col_Name_Vec,
                   Row1_Present => Length (Rows) > 1,
                   Row1         => Item (Rows, 1),
                   Final_Names  => Final_Names);
               Load_ODF_Data_Rows (Rows, Col_Names => Final_Names);
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
      Parse_Declared_Types (Declared_Types, Declared_List);
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
   procedure Write_ODF (File_Name     : String; Sheet_Name : String := "Sheet1";
                        Decimals      : Integer := -1;
                        Missing_Token : String  := "";
                        View          : SData_Core.Table.Table_View :=
                           SData_Core.Table.Default_View) is
      use Zip.Create;
      Info          : Zip_Create_Info;
      Z_File_Stream : aliased Zip_File_Stream;
      N             : constant Natural := Column_Count (View);
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
               Escape_XML (Column_Name (C, View)) & "</text:p></table:table-cell>");
         end loop;
         Append (S1, "</table:table-row>" & ASCII.LF);

         --  Iterate the logical (post-SELECT) view; identity when unfiltered.
         for L in 1 .. Logical_Row_Count (View) loop
            SData_Core.IO.Show_Progress ("SAVE", L);
            Append (S1, "<table:table-row>");
            for C in 1 .. N loop
               declare
                  R : constant Positive := Logical_To_Physical (L, View);
                  V : constant Value := Get_Value (R, Column_Name (C, View), View);
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
                        --  sdata ADR-083 / sdata-core ADR-0026: SAVE's
                        --  write-side MISSING= token, written as a string
                        --  cell when given (verbatim, never split -- see
                        --  the CSV writer's comment for the read/write
                        --  asymmetry rationale); an empty cell (today's
                        --  behavior) when omitted.
                        if Missing_Token = "" then
                           Append (S1, "<table:table-cell/>");
                        else
                           Append (S1,
                              "<table:table-cell office:value-type=""string""><text:p>" &
                              Escape_XML (Missing_Token) &
                              "</text:p></table:table-cell>");
                        end if;
                  end case;
               end;
            end loop;
            Append (S1, "</table:table-row>" & ASCII.LF);
         end loop;
         SData_Core.IO.Show_Progress ("SAVE", Logical_Row_Count (View), Final => True);

         Append (S1,
            "</table:table></office:spreadsheet></office:body></office:document-content>");
         Add_String (Info, S1, "content.xml");
      end;

      Finish (Info);
   end Write_ODF;

end SData_Core.File_IO.ODF;