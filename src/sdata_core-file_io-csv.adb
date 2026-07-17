--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Ada.Streams;
with Ada.Directories;
with Ada.Strings.UTF_Encoding;             use Ada.Strings.UTF_Encoding;
with Ada.Strings.UTF_Encoding.Conversions;
with SData_Core.Config.Runtime;
with Ada.Unchecked_Deallocation;
with SData_Core.IO;                use SData_Core.IO;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;       use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
with SData_Core.Table;             use SData_Core.Table;
with SData_Core.Values;            use SData_Core.Values;
with GNAT.Strings;            use GNAT.Strings;
with SData_Core.CSV;               use SData_Core.CSV;
with SData_Core.File_IO.Helpers;   use SData_Core.File_IO.Helpers;

package body SData_Core.File_IO.CSV is

   package Line_Vecs     is new Ada.Containers.Vectors (Positive, Unbounded_String);
   package Col_Name_Vecs is new Ada.Containers.Vectors
      (Positive, GNAT.Strings.String_Access);
   package Col_Type_Vecs is new Ada.Containers.Vectors (Positive, Column_Type);

   procedure Split_Into_Lines (S : String; All_Lines : in out Line_Vecs.Vector) is
      Start : Natural := S'First;
      I     : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = ASCII.LF then
            declare
               E : Natural := I - 1;
            begin
               if E >= Start and then S (E) = ASCII.CR then
                  E := E - 1;
               end if;
               All_Lines.Append (To_Unbounded_String
                  (if E >= Start then S (Start .. E) else ""));
            end;
            Start := I + 1;
         end if;
         I := I + 1;
      end loop;
      if Start <= S'Last then
         All_Lines.Append (To_Unbounded_String (S (Start .. S'Last)));
      end if;
   end Split_Into_Lines;

   procedure Load_As_UTF16
      (File_Name   : String;
       Scheme      : Ada.Strings.UTF_Encoding.Encoding_Scheme;
       All_Lines   : in out Line_Vecs.Vector;
       Is_Buffered : out Boolean)
   is
      F    : Ada.Streams.Stream_IO.File_Type;
      Sz   : constant Ada.Directories.File_Size :=
         Ada.Directories.Size (File_Name);
      Buf  : Ada.Streams.Stream_Element_Array
         (1 .. Ada.Streams.Stream_Element_Offset (Sz));
      Last : Ada.Streams.Stream_Element_Offset;
      Raw  : String (1 .. Natural (Sz));
   begin
      Is_Buffered := False;
      Ada.Streams.Stream_IO.Open
         (F, Ada.Streams.Stream_IO.In_File, File_Name);
      Ada.Streams.Stream_IO.Read (F, Buf, Last);
      Ada.Streams.Stream_IO.Close (F);
      for I in 1 .. Natural (Last) loop
         Raw (I) :=
            Character'Val (Buf (Ada.Streams.Stream_Element_Offset (I)));
      end loop;
      declare
         UTF8     : constant String :=
            Ada.Strings.UTF_Encoding.Conversions.Convert
               (Raw (1 .. Natural (Last)), Scheme,
                Ada.Strings.UTF_Encoding.UTF_8);
         Start_At : Natural := UTF8'First;
      begin
         if UTF8'Length >= 3
            and then UTF8 (UTF8'First .. UTF8'First + 2) = BOM_8
         then
            Start_At := UTF8'First + 3;
         end if;
         Split_Into_Lines (UTF8 (Start_At .. UTF8'Last), All_Lines);
         Is_Buffered := True;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (F) then
            Ada.Streams.Stream_IO.Close (F);
         end if;
         raise;
   end Load_As_UTF16;

   procedure Detect_And_Load
      (File_Name   : String;
       All_Lines   : in out Line_Vecs.Vector;
       Is_Buffered : out Boolean)
   is
      use Ada.Streams;
      F      : Ada.Streams.Stream_IO.File_Type;
      Detect : Ada.Streams.Stream_Element_Array (1 .. 4);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Is_Buffered := False;
      Ada.Streams.Stream_IO.Open
         (F, Ada.Streams.Stream_IO.In_File, File_Name);
      Ada.Streams.Stream_IO.Read (F, Detect, Last);
      Ada.Streams.Stream_IO.Close (F);
      if Last >= 2
         and then Detect (1) = 16#FF# and then Detect (2) = 16#FE#
      then
         Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16LE,
                        All_Lines, Is_Buffered);
      elsif Last >= 2
         and then Detect (1) = 16#FE# and then Detect (2) = 16#FF#
      then
         Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16BE,
                        All_Lines, Is_Buffered);
      end if;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (F) then
            Ada.Streams.Stream_IO.Close (F);
         end if;
         raise;
   end Detect_And_Load;

   ---------------
   -- Parse_CSV --
   ---------------
   procedure Parse_CSV (File_Name   : String;
                        Delimiter   : String  := ",";
                        Read_Header : Boolean := True;
                        Charset     : String  := "";
                        Skip_Rows   : Natural := 0;
                        Max_Rows    : Natural := 0;
                        Nscan_Rows  : Natural := 0) is
      File : Ada.Text_IO.File_Type;

      All_Lines       : Line_Vecs.Vector;
      All_Lines_Idx   : Natural := 0;
      Is_Buffered     : Boolean := False;
      Needs_ASCII_Chk : Boolean := False;
      Rows_Written    : Natural := 0;

      procedure Validate_ASCII (S : String) is
      begin
         for I in S'Range loop
            if Character'Pos (S (I)) > 127 then
               SData_Core.IO.Put_Line_Error
                  ("Warning: non-ASCII byte (value" &
                   Integer'Image (Character'Pos (S (I))) &
                   ") found in """ & File_Name & """");
               return;
            end if;
         end loop;
      end Validate_ASCII;

      Max_Line : constant := 1_048_576;
      subtype Line_Buf_T is String (1 .. Max_Line);
      type    Line_Buf_Access is access Line_Buf_T;
      procedure Free_Buf is new
         Ada.Unchecked_Deallocation (Line_Buf_T, Line_Buf_Access);

      Line_Buf  : Line_Buf_Access := new Line_Buf_T;
      Line_Last : Natural := 0;

      Col_Names : Col_Name_Vecs.Vector;
      Col_Types : Col_Type_Vecs.Vector;

      procedure Process_Line_Direct (Line : String) is
         DLen         : constant Positive :=
            (if Delimiter'Length > 0 then Delimiter'Length else 1);
         Start        : Integer := Line'First;
         Field_Count  : Natural := 0;
         N_Cols       : constant Natural := Natural (Col_Names.Length);
         Warned_Extra : Boolean := False;
      begin
         if Max_Rows > 0 and then Rows_Written >= Max_Rows then
            return;
         end if;
         Rows_Written := Rows_Written + 1;
         Add_Row;
         SData_Core.IO.Show_Progress ("USE", Rows_Written);
         loop
            declare
               Delim_Pos : constant Natural :=
                  CSV_Field_End (Line, Start, Delimiter);
               Val : Value;
               Num : Real;
            begin
               declare
                  Raw : constant String :=
                     (if Delim_Pos > 0 then Line (Start .. Delim_Pos - 1)
                      else                  Line (Start .. Line'Last));
                  F : constant String := CSV_Unquote (Raw);
               begin
                  Field_Count := Field_Count + 1;

                  --  Detect unclosed/malformed quote: CSV_Unquote strips
                  --  matched opening+closing quotes; if the result still
                  --  starts with a quote character the closing quote was
                  --  absent and the field value is corrupt.
                  if F'Length > 0
                     and then (F (F'First) = '"' or else F (F'First) = ''')
                  then
                     SData_Core.IO.Put_Line_Error
                        ("Warning: """ & File_Name & """, data row" &
                         Natural'Image (Rows_Written) & ", column" &
                         Natural'Image (Field_Count) &
                         ": unclosed quote -- value includes the quote character");
                  end if;

                  if Field_Count <= N_Cols then
                     if F = "" or else F = "." then
                        Val := (Kind => Val_Missing);
                     elsif Col_Types (Field_Count) /= Col_String
                        and then Try_Fast_Float (F, Num)
                     then
                        if Col_Types (Field_Count) = Col_Integer
                           and then Num /= Real'Truncation (Num)
                        then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-integer value """ & F &
                               """ in integer column -- truncated");
                        end if;
                        Val := (Kind => Val_Numeric, Num_Val => Num);
                     else
                        --  Non-numeric value in a column typed numeric or
                        --  integer: store as missing rather than as a string
                        --  so that arithmetic on the column stays well-typed.
                        if Col_Types (Field_Count) = Col_Numeric then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-numeric value """ & F &
                               """ in numeric column -- stored as missing");
                           Val := (Kind => Val_Missing);
                        elsif Col_Types (Field_Count) = Col_Integer then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-numeric value """ & F &
                               """ in integer column -- stored as missing");
                           Val := (Kind => Val_Missing);
                        else
                           Val := (Kind    => Val_String,
                                   Str_Val => To_Unbounded_String (F));
                        end if;
                     end if;
                     begin
                        Set_Value_Upper
                           (Row_Count, Col_Names (Field_Count).all, Val);
                     exception
                        when Constraint_Error =>
                           --  Out-of-range value for a % (integer) column:
                           --  warn and store missing rather than aborting the
                           --  load.  (Other column kinds re-raise as before.)
                           if Col_Types (Field_Count) = Col_Integer then
                              SData_Core.IO.Put_Line_Error
                                 ("Warning: """ & File_Name & """, data row" &
                                  Natural'Image (Rows_Written) & ", column """ &
                                  Col_Names (Field_Count).all &
                                  """: value """ & F &
                                  """ out of integer range -- stored as missing");
                              Set_Value_Upper
                                 (Row_Count, Col_Names (Field_Count).all,
                                  (Kind => Val_Missing));
                           else
                              raise;
                           end if;
                     end;
                  elsif not Warned_Extra then
                     SData_Core.IO.Put_Line_Error
                        ("Warning: """ & File_Name & """, data row" &
                         Natural'Image (Rows_Written) &
                         ": row has more fields than the" &
                         Natural'Image (N_Cols) &
                         " defined columns -- extra fields ignored");
                     Warned_Extra := True;
                  end if;
               end;
               exit when Delim_Pos = 0;
               Start := Delim_Pos + DLen;
            end;
         end loop;

         --  Short row: non-empty line with fewer fields than columns.
         if Line'Length > 0 and then Field_Count < N_Cols then
            SData_Core.IO.Put_Line_Error
               ("Warning: """ & File_Name & """, data row" &
                Natural'Image (Rows_Written) &
                ": only" & Natural'Image (Field_Count) &
                " of" & Natural'Image (N_Cols) &
                " expected fields present -- missing columns set to missing");
         end if;
      end Process_Line_Direct;

      Has_File_Header : Boolean := False;
      Max_NSCAN   : constant := 1000;
      NSCAN       : constant Natural :=
         (if Nscan_Rows > 0 then Natural'Min (Nscan_Rows, Max_NSCAN) else 20);

      type UB_Array is array (1 .. Max_NSCAN) of Unbounded_String;
      Scan_Lines  : UB_Array;
      Scan_Count  : Natural := 0;
      Header_Line : Unbounded_String;

      procedure Infer_Column_Types
         (H_Str : String; Names_From_Header : Boolean)
      is
         H_Fields : Field_Vectors.Vector;
         N_Hdr    : Natural;
      begin
         Split_Indices (H_Str, Delimiter, H_Fields);
         N_Hdr := Natural (H_Fields.Length);

         Col_Types := Col_Type_Vecs.To_Vector
            (Col_Numeric, Ada.Containers.Count_Type (N_Hdr));
         Col_Names.Clear;

         declare
            Col_Determined : array (1 .. N_Hdr) of Boolean := (others => False);
         begin
            if Names_From_Header then
               for I in 1 .. N_Hdr loop
                  declare
                     Raw : constant String :=
                        Trim (H_Str (H_Fields (I).S .. H_Fields (I).E),
                              Ada.Strings.Both);
                  begin
                     if Raw'Length > 0 and then Raw (Raw'Last) = '$' then
                        Col_Types.Replace_Element (I, Col_String);
                        Col_Determined (I) := True;
                     elsif Raw'Length > 0 and then Raw (Raw'Last) = '%' then
                        Col_Types.Replace_Element (I, Col_Integer);
                        Col_Determined (I) := True;
                     end if;
                  end;
               end loop;
            end if;

            declare
               D_Fields : Field_Vectors.Vector;
            begin
               for R in 1 .. Scan_Count loop
                  declare
                     D_Str : constant String := To_String (Scan_Lines (R));
                  begin
                     Split_Indices (D_Str, Delimiter, D_Fields);
                     for I in 1 .. N_Hdr loop
                        if not Col_Determined (I)
                           and then I <= Natural (D_Fields.Length)
                        then
                           declare
                              F : constant String :=
                                 CSV_Unquote
                                    (D_Str (D_Fields (I).S .. D_Fields (I).E));
                           begin
                              if F /= "" and then F /= "." then
                                 Col_Types.Replace_Element
                                    (I, (if Is_Numeric_Field (F) then Col_Numeric
                                         else Col_String));
                                 Col_Determined (I) := True;
                              end if;
                           end;
                        end if;
                     end loop;
                  end;
               end loop;
            end;

            for I in 1 .. N_Hdr loop
               declare
                  Base_Name : constant String :=
                     (if Names_From_Header
                      then Safe_Name
                              (CSV_Unquote (H_Str (H_Fields (I).S .. H_Fields (I).E)),
                               "COL" & Trim (I'Img, Ada.Strings.Both))
                      else "COL" & Trim (I'Img, Ada.Strings.Both));
                  Name : constant String :=
                     (if Col_Types (I) = Col_String
                         and then (Base_Name'Length = 0
                                   or else Base_Name (Base_Name'Last) /= '$')
                      then Base_Name & "$"
                      else Base_Name);
               begin
                  Col_Names.Append (new String'(Name));
               end;
            end loop;
         end;
      end Infer_Column_Types;

      procedure Load_Data_Rows is
         N : constant Natural := Natural (Col_Names.Length);
      begin
         Clear;
         for I in 1 .. N loop
            Add_Column (Col_Names (I).all, Col_Types (I));
         end loop;

         if Has_File_Header and then Scan_Count = 0 then
            SData_Core.IO.Put_Line_Error
               ("Warning: File contains a header but no data records.");
         end if;

         for R in 1 .. Scan_Count loop
            exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
            Process_Line_Direct (To_String (Scan_Lines (R)));
         end loop;

         if Is_Buffered then
            while All_Lines_Idx < Natural (All_Lines.Length) loop
               exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
               All_Lines_Idx := All_Lines_Idx + 1;
               Process_Line_Direct (To_String (All_Lines (All_Lines_Idx)));
            end loop;
         else
            while not Ada.Text_IO.End_Of_File (File) loop
               exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
               Ada.Text_IO.Get_Line (File, Line_Buf.all, Line_Last);
               if Needs_ASCII_Chk then
                  Validate_ASCII (Line_Buf (1 .. Line_Last));
               end if;
               Process_Line_Direct (Line_Buf (1 .. Line_Last));
            end loop;
         end if;

         for SA of Col_Names loop Free (SA); end loop;
         Col_Names.Clear;
      end Load_Data_Rows;

   begin
      declare
         UC : constant String := To_Upper (Trim (Charset, Ada.Strings.Both));
      begin
         if UC = "UTF-16" or else UC = "UTF-16LE" then
            Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16LE,
                           All_Lines, Is_Buffered);
         elsif UC = "UTF-16BE" then
            Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16BE,
                           All_Lines, Is_Buffered);
         elsif UC = "" or else UC = "AUTO" then
            Detect_And_Load (File_Name, All_Lines, Is_Buffered);
         elsif UC = "ASCII" then
            Needs_ASCII_Chk := True;
         end if;
      end;

      if not Is_Buffered then
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, File_Name);
      end if;

      if Is_Buffered then
         if Read_Header and then Natural (All_Lines.Length) >= 1 then
            Header_Line     := All_Lines (1);
            Has_File_Header := True;
            All_Lines_Idx   := 1;
         end if;
         if Skip_Rows > 0 then
            All_Lines_Idx :=
               Natural'Min (All_Lines_Idx + Skip_Rows, Natural (All_Lines.Length));
         end if;
         while All_Lines_Idx < Natural (All_Lines.Length)
            and then Scan_Count < NSCAN
            and then (Max_Rows = 0 or else Scan_Count < Max_Rows)
         loop
            All_Lines_Idx := All_Lines_Idx + 1;
            Scan_Count    := Scan_Count + 1;
            Scan_Lines (Scan_Count) := All_Lines (All_Lines_Idx);
         end loop;
      else
         if Read_Header then
            if not Ada.Text_IO.End_Of_File (File) then
               Ada.Text_IO.Get_Line (File, Line_Buf.all, Line_Last);
               declare
                  L : constant String := Line_Buf (1 .. Line_Last);
               begin
                  if L'Length >= 3
                     and then L (L'First .. L'First + 2) = BOM_8
                  then
                     Header_Line :=
                        To_Unbounded_String (L (L'First + 3 .. L'Last));
                  else
                     Header_Line := To_Unbounded_String (L);
                  end if;
               end;
               Has_File_Header := True;
            end if;
         end if;

         for I in 1 .. Skip_Rows loop
            exit when Ada.Text_IO.End_Of_File (File);
            Ada.Text_IO.Get_Line (File, Line_Buf.all, Line_Last);
            if Needs_ASCII_Chk then
               Validate_ASCII (Line_Buf (1 .. Line_Last));
            end if;
         end loop;

         while not Ada.Text_IO.End_Of_File (File)
            and then Scan_Count < NSCAN
            and then (Max_Rows = 0 or else Scan_Count < Max_Rows)
         loop
            Ada.Text_IO.Get_Line (File, Line_Buf.all, Line_Last);
            if Needs_ASCII_Chk then
               Validate_ASCII (Line_Buf (1 .. Line_Last));
            end if;
            Scan_Count := Scan_Count + 1;
            Scan_Lines (Scan_Count) :=
               To_Unbounded_String (Line_Buf (1 .. Line_Last));
         end loop;
      end if;

      if Has_File_Header then
         Infer_Column_Types (To_String (Header_Line), Names_From_Header => True);
         Load_Data_Rows;
      elsif Scan_Count > 0 then
         Infer_Column_Types (To_String (Scan_Lines (1)), Names_From_Header => False);
         Load_Data_Rows;
      end if;

      Free_Buf (Line_Buf);
      if Ada.Text_IO.Is_Open (File) then
         Ada.Text_IO.Close (File);
      end if;
   exception
      when others =>
         Free_Buf (Line_Buf);
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Parse_CSV;

   ---------------
   -- Write_CSV --
   ---------------
   procedure Write_CSV (File_Name       : String;
                        Delimiter       : String  := ",";
                        Write_Header    : Boolean := True;
                        Allow_Overwrite : Boolean := True;
                        Charset         : String  := "";
                        Decimals        : Integer := -1) is
      use Ada.Directories;

      TXTFMT_Len : constant Natural := SData_Core.Config.Runtime.Options_TXTFMT_Len;
      TXTFMT_Raw : constant String  :=
         (if TXTFMT_Len > 0 then SData_Core.Config.Runtime.Options_TXTFMT (1 .. TXTFMT_Len)
          else "AUTO");
      EOL : constant String :=
         (if    TXTFMT_Raw = "CRLF" then "" & ASCII.CR & ASCII.LF
          elsif TXTFMT_Raw = "CR"   then "" & ASCII.CR
          else                           "" & ASCII.LF);

      Eff_Charset  : constant String :=
         To_Upper (Trim (Charset, Ada.Strings.Both));
      Is_UTF16     : constant Boolean :=
         Eff_Charset = "UTF-16" or else
         Eff_Charset = "UTF-16LE" or else
         Eff_Charset = "UTF-16BE";
      Is_UTF16BE_W : constant Boolean := Eff_Charset = "UTF-16BE";
      Is_ASCII_Chk : constant Boolean := Eff_Charset = "ASCII";
      Out_Scheme   : constant Ada.Strings.UTF_Encoding.Encoding_Scheme :=
         (if Is_UTF16BE_W
          then Ada.Strings.UTF_Encoding.UTF_16BE
          else Ada.Strings.UTF_Encoding.UTF_16LE);
      Out_BOM      : constant String :=
         (if Is_UTF16 then (if Is_UTF16BE_W then BOM_16BE else BOM_16LE)
          else "");

      File  : Ada.Streams.Stream_IO.File_Type;
      Strm  : Ada.Streams.Stream_IO.Stream_Access;
      N     : constant Natural := Column_Count;
      D_Str : constant String := Delimiter;

      procedure Write_String (S : String) is
      begin
         if Is_UTF16 then
            String'Write (Strm,
               Ada.Strings.UTF_Encoding.Conversions.Convert
                  (S, Ada.Strings.UTF_Encoding.UTF_8, Out_Scheme));
         else
            if Is_ASCII_Chk then
               for I in S'Range loop
                  if Character'Pos (S (I)) > 127 then
                     SData_Core.IO.Put_Line_Error
                        ("Warning: non-ASCII byte (value" &
                         Integer'Image (Character'Pos (S (I))) &
                         ") in output for """ & File_Name & """");
                     exit;
                  end if;
               end loop;
            end if;
            String'Write (Strm, S);
         end if;
      end Write_String;

      function CSV_Quote (S : String) return String is
         Needs_Quote : Boolean := False;
         Quote_Count : Natural := 0;
      begin
         for I in S'Range loop
            if S (I) = '"' then
               Needs_Quote := True;
               Quote_Count := Quote_Count + 1;
            elsif D_Str'Length > 0 and then
                  I + D_Str'Length - 1 <= S'Last and then
                  S (I .. I + D_Str'Length - 1) = D_Str
            then
               Needs_Quote := True;
            elsif S (I) = ASCII.LF or else S (I) = ASCII.CR then
               Needs_Quote := True;
            end if;
         end loop;

         if not Needs_Quote then
            return S;
         end if;

         declare
            Res : String (1 .. S'Length + Quote_Count + 2);
            J   : Positive := 2;
         begin
            Res (1) := '"';
            for I in S'Range loop
               if S (I) = '"' then
                  Res (J) := '"';
                  Res (J + 1) := '"';
                  J := J + 2;
               else
                  Res (J) := S (I);
                  J := J + 1;
               end if;
            end loop;
            Res (Res'Last) := '"';
            return Res;
         end;
      end CSV_Quote;

   begin
      if not Allow_Overwrite and then Exists (File_Name) then
         SData_Core.IO.Put_Line_Error
            ("Error: SAVE aborted -- file already exists: " & File_Name &
             " (use OPTIONS SAVEOVERWRT YES to allow overwriting)");
         raise SData_Core.File_IO.Save_Refused;
      end if;
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, File_Name);
      Strm := Ada.Streams.Stream_IO.Stream (File);
      if Is_UTF16 then
         String'Write (Strm, Out_BOM);
      end if;
      if N > 0 then
         if Write_Header then
            for I in 1 .. N loop
               Write_String (CSV_Quote (Column_Name (I)));
               if I /= N then
                  Write_String (D_Str);
               end if;
            end loop;
            Write_String (EOL);
         end if;
         --  Iterate the logical (post-SELECT) view: Logical_Row_Count and
         --  Logical_To_Physical collapse to Row_Count / identity when no
         --  filter is active, so an unfiltered SAVE is byte-for-byte
         --  unchanged.  The caller (Execute_RUN / Commit_Step) rebuilds the
         --  filter map before flushing, matching DISPLAY's contract.
         for L in 1 .. Logical_Row_Count loop
            SData_Core.IO.Show_Progress ("SAVE", L);
            declare
               R : constant Positive := Logical_To_Physical (L);
            begin
               for C in 1 .. N loop
                  declare
                     Val : constant Value :=
                        Get_Value_Upper (R, Column_Name (C));
                  begin
                     if Val.Kind = Val_Numeric then
                        if Is_Inf (Val.Num_Val) then
                           Write_String
                              (if Val.Num_Val > 0.0 then "Inf" else "-Inf");
                        elsif Decimals >= 0 then
                           Write_String
                              (SData_Core.Values.Image_Fixed_Decimals
                                 (Val.Num_Val, Decimals));
                        else
                           Write_String
                              (SData_Core.Values.Image_Round_Trip (Val.Num_Val));
                        end if;
                     elsif Val.Kind = Val_Integer then
                        Write_String (Trim (Val.Int_Val'Img, Ada.Strings.Both));
                     elsif Val.Kind = Val_String then
                        Write_String (CSV_Quote (SData_Core.Values.To_String (Val)));
                     end if;
                  end;
                  if C /= N then
                     Write_String (D_Str);
                  end if;
               end loop;
            end;
            Write_String (EOL);
         end loop;
         SData_Core.IO.Show_Progress ("SAVE", Logical_Row_Count, Final => True);
      end if;
      Ada.Streams.Stream_IO.Close (File);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         raise;
   end Write_CSV;

end SData_Core.File_IO.CSV;