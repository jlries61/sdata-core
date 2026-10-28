--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Streams.Stream_IO;
with Ada.Streams;
with Ada.Directories;
with Ada.Strings.UTF_Encoding;             use Ada.Strings.UTF_Encoding;
with Ada.Strings.UTF_Encoding.Conversions;
with SData_Core.Config.Runtime;
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

   --  Record reader (F01/F02/F24, 2026-10-19 stress test).  Replaces
   --  Ada.Text_IO.Get_Line, which split only on LF (leaving the CR of CRLF
   --  files in the last field, and reading a bare-CR file as one giant line),
   --  split quoted fields containing newlines into several records, and cut
   --  any line at a fixed 1 MiB buffer.  A record ends at LF, CRLF or a bare
   --  CR that is outside a double-quoted field; line breaks inside a quoted
   --  field are kept verbatim.  There is no length limit.  A quote opens a
   --  quoted field only at the start of a field (as CSV_Field_End parses it),
   --  so a stray quote in mid-field (5" pipe) does not swallow later lines.
   type Record_Reader is limited record
      File    : Ada.Streams.Stream_IO.File_Type;
      Is_File : Boolean := False;
      Chunk   : GNAT.Strings.String_Access := null;
      Pos     : Natural := 1;
      Last    : Natural := 0;
      Recbuf  : GNAT.Strings.String_Access := null;
      Rec_Len : Natural := 0;
   end record;

   Chunk_Size : constant := 65_536;

   procedure Open_File (R : in out Record_Reader; Name : String) is
   begin
      Ada.Streams.Stream_IO.Open
         (R.File, Ada.Streams.Stream_IO.In_File, Name);
      R.Is_File := True;
      R.Chunk   := new String (1 .. Chunk_Size);
      R.Pos     := 1;
      R.Last    := 0;
   end Open_File;

   procedure Open_Memory (R : in out Record_Reader; S : String) is
   begin
      R.Is_File := False;
      R.Chunk   := new String'(S);
      R.Pos     := 1;
      R.Last    := S'Length;
   end Open_Memory;

   procedure Close (R : in out Record_Reader) is
   begin
      if R.Is_File and then Ada.Streams.Stream_IO.Is_Open (R.File) then
         Ada.Streams.Stream_IO.Close (R.File);
      end if;
      GNAT.Strings.Free (R.Chunk);
      GNAT.Strings.Free (R.Recbuf);
      R.Rec_Len := 0;
   end Close;

   --  True when at least one more byte is available.
   function More (R : in out Record_Reader) return Boolean is
      use Ada.Streams;
   begin
      if R.Pos <= R.Last then
         return True;
      end if;
      if R.Is_File and then Ada.Streams.Stream_IO.Is_Open (R.File)
         and then not Ada.Streams.Stream_IO.End_Of_File (R.File)
      then
         declare
            Buf : Stream_Element_Array (1 .. Stream_Element_Offset (Chunk_Size));
            Got : Stream_Element_Offset;
         begin
            Ada.Streams.Stream_IO.Read (R.File, Buf, Got);
            for I in 1 .. Got loop
               R.Chunk (Integer (I)) := Character'Val (Buf (I));
            end loop;
            R.Pos  := 1;
            R.Last := Integer (Got);
         end;
      end if;
      return R.Pos <= R.Last;
   end More;

   --  Reads the next record into R.Recbuf (1 .. R.Rec_Len).
   procedure Read_Record (R : in out Record_Reader; Delimiter : String) is
      Delim  : constant String :=
         (if Delimiter'Length > 0 then Delimiter else ",");
      DLen   : constant Positive := Delim'Length;
      In_Q   : Boolean := False;
      Q_Pend : Boolean := False;   --  saw a quote while inside quotes

      procedure Append (C : Character) is
      begin
         if R.Recbuf = null then
            R.Recbuf := new String (1 .. 4096);
         elsif R.Rec_Len = R.Recbuf'Last then
            declare
               Bigger : constant GNAT.Strings.String_Access :=
                  new String (1 .. R.Recbuf'Last * 2);
            begin
               Bigger (1 .. R.Rec_Len) := R.Recbuf (1 .. R.Rec_Len);
               GNAT.Strings.Free (R.Recbuf);
               R.Recbuf := Bigger;
            end;
         end if;
         R.Rec_Len := R.Rec_Len + 1;
         R.Recbuf (R.Rec_Len) := C;
      end Append;

      function At_Field_Start return Boolean is
        (R.Rec_Len = 0
         or else (R.Rec_Len >= DLen
                  and then R.Recbuf (R.Rec_Len - DLen + 1 .. R.Rec_Len)
                           = Delim));
   begin
      R.Rec_Len := 0;
      while More (R) loop
         declare
            C    : constant Character := R.Chunk (R.Pos);
            Done : Boolean := False;   --  C already consumed by quote logic
         begin
            R.Pos := R.Pos + 1;
            if In_Q and then Q_Pend then
               Q_Pend := False;
               if C = '"' then
                  Append (C);          --  doubled quote: literal
                  Done := True;
               else
                  In_Q := False;       --  the pending quote closed the field
               end if;
            elsif In_Q then
               Append (C);
               Q_Pend := (C = '"');
               Done := True;
            end if;
            if not Done then
               if C = ASCII.LF then
                  return;
               elsif C = ASCII.CR then
                  if More (R) and then R.Chunk (R.Pos) = ASCII.LF then
                     R.Pos := R.Pos + 1;
                  end if;
                  return;
               else
                  if C = '"' and then At_Field_Start then
                     In_Q   := True;
                     Q_Pend := False;
                  end if;
                  Append (C);
               end if;
            end if;
         end;
      end loop;
   end Read_Record;

   procedure Split_Into_Lines
      (S          : String;
       All_Lines  : in out Line_Vecs.Vector;
       Delimiter  : String := ",")
   is
      R : Record_Reader;
   begin
      Open_Memory (R, S);
      while More (R) loop
         Read_Record (R, Delimiter);
         All_Lines.Append (To_Unbounded_String (R.Recbuf (1 .. R.Rec_Len)));
      end loop;
      Close (R);
   exception
      when others =>
         Close (R);
         raise;
   end Split_Into_Lines;

   procedure Load_As_UTF16
      (File_Name   : String;
       Scheme      : Ada.Strings.UTF_Encoding.Encoding_Scheme;
       All_Lines   : in out Line_Vecs.Vector;
       Is_Buffered : out Boolean;
       Delimiter   : String := ",")
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
         Split_Into_Lines (UTF8 (Start_At .. UTF8'Last), All_Lines, Delimiter);
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
       Is_Buffered : out Boolean;
       Delimiter   : String := ",")
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
                        All_Lines, Is_Buffered, Delimiter);
      elsif Last >= 2
         and then Detect (1) = 16#FE# and then Detect (2) = 16#FF#
      then
         Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16BE,
                        All_Lines, Is_Buffered, Delimiter);
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
   procedure Parse_CSV (File_Name      : String;
                        Delimiter      : String  := ",";
                        Read_Header    : Boolean := True;
                        Charset        : String  := "";
                        Skip_Rows      : Natural := 0;
                        Max_Rows       : Natural := 0;
                        Nscan_Rows     : Natural := 0;
                        Missing_Tokens : String  := "";
                        Declared_Types : String  := "") is
      Rdr : Record_Reader;

      All_Lines       : Line_Vecs.Vector;
      All_Lines_Idx   : Natural := 0;
      Is_Buffered     : Boolean := False;
      Needs_ASCII_Chk : Boolean := False;
      Rows_Written    : Natural := 0;

      --  ADR-0020 (PD-7): counts non-numeric-value-in-numeric/integer-column
      --  coercion warnings across this whole Parse_CSV call (i.e. per source
      --  file -- a multi-file USE merge calls Parse_CSV once per source, so
      --  each gets its own independent cap for free).  Design.md's "maximum
      --  of 10 shall be written" only describes these two warning sites
      --  (below); the sibling warnings in this procedure (unclosed quote,
      --  non-integer truncation, integer out-of-range, extra fields) are
      --  deliberately NOT counted here.
      Coercion_Warn_Count : Natural := 0;
      Coercion_Warn_Cap    : constant := 10;

      --  ADR-0021 (PD-8): design.md §4.1/§4.5 state four times that a
      --  charset violation fails the operation with an error message; this
      --  used to warn and continue.  Raise on the first offending byte,
      --  matching this procedure's own pre-existing short-circuit
      --  granularity (one message per call, not exhaustive per byte).
      procedure Validate_ASCII (S : String) is
      begin
         for I in S'Range loop
            if Character'Pos (S (I)) > 127 then
               raise SData_Core.Script_Error with
                  """" & File_Name & """: non-ASCII byte (value" &
                  Integer'Image (Character'Pos (S (I))) &
                  ") in input -- rejected (CHARSET=ASCII)";
            end if;
         end loop;
      end Validate_ASCII;

      Col_Names : Col_Name_Vecs.Vector;
      Col_Types : Col_Type_Vecs.Vector;

      --  sdata ADR-083 / sdata-core ADR-0026: user-declared MISSING= tokens
      --  (USE's read side).  Built once, below, from Missing_Tokens; consulted
      --  identically by Infer_Column_Types's scan-window loop and
      --  Process_Line_Direct's per-row load loop so a declared token can
      --  never have a different outcome depending on which row it lands on
      --  -- the exact asymmetry this feature exists to close for a declared
      --  sentinel (the underlying NSCAN-window inference rule itself,
      --  ADR-0019, is unchanged and still applies to any *undeclared*
      --  anomaly).  Each token is CSV-unquoted and trimmed, the same
      --  treatment Infer_Column_Types already gives a header column name
      --  below -- a field's own VALUE is compared untrimmed, exactly like
      --  the pre-existing "" / "." checks, so declaring a token adds no new
      --  whitespace sensitivity to data comparison, only to how the token
      --  list itself is written.
      --
      --  SCOPE: numeric columns only (ADR-0026, "Numeric columns only",
      --  amended 2026-09-25).  Both call sites are therefore reached only for a
      --  column that is numeric or still a numeric candidate: the scan-window
      --  loop runs only while a column's type is undetermined, and the per-row
      --  load guards the call with Col_Types (...) /= Col_String.  A character
      --  column stores text as text, declared token or not.
      --
      --  ADR-0026 (amended): the token list and its match predicate now live
      --  in File_IO.Helpers, shared with ODF/OOXML.  Missing_Token_List is
      --  populated once, below in the main body, via Parse_Missing_Tokens.
      Missing_Token_List  : Missing_Token_Vecs.Vector;
      Missing_Match_Count : Natural := 0;

      --  ADR-084: /TYPES= declarations, parsed once per call (below, in the
      --  main body) and applied in Infer_Column_Types before the scan loop.
      Declared_List : Declared_Vecs.Vector;

      --  F42 (2026-10-19 stress test): an integer (%) column used to be
      --  parsed through Real, so ids above 2**53 silently lost digits and
      --  values near the int64 limits overflowed on conversion.  A plain
      --  [+-]digits field is parsed exactly; anything else (decimals, E
      --  notation, out-of-range) falls through to the existing paths.
      function Try_Exact_Int (F : String; Result : out Int) return Boolean is
         T : constant String := Ada.Strings.Fixed.Trim (F, Ada.Strings.Both);
         B : Integer := T'First;
      begin
         Result := 0;
         if T'Length = 0 then
            return False;
         end if;
         if T (B) = '-' or else T (B) = '+' then
            B := B + 1;
         end if;
         if B > T'Last then
            return False;
         end if;
         for K in B .. T'Last loop
            if T (K) not in '0' .. '9' then
               return False;
            end if;
         end loop;
         Result := Int'Value (if T (T'First) = '+' then T (T'First + 1 .. T'Last) else T);
         return True;
      exception
         when Constraint_Error => return False;
      end Try_Exact_Int;

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
         --  A blank line (nothing before the line end) is not a record
         --  (F16): pandas, R and SAS skip it too.  A line of delimiters only
         --  is still a record with every field missing.
         if Line'Length = 0 then
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
               Exact : Int;
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
                        and then Is_Declared_Missing (Missing_Token_List, F)
                     then
                        --  A declared MISSING= token is expected, not an
                        --  anomaly -- no per-value warning (unlike the
                        --  coercion-warning branches below), just a single
                        --  summary count printed once at the end of the load
                        --  (Load_Data_Rows, below).
                        --
                        --  NUMERIC COLUMNS ONLY (ADR-0026, "Numeric columns
                        --  only", amended 2026-09-25).  A character column stores
                        --  text as text: a declared token that also happens to
                        --  be a legitimate string value there (the textbook
                        --  case is "NA" as Nebraska's state code in a CODE$
                        --  column) must NOT be silently discarded just because
                        --  some *other*, numeric column in the same file needed
                        --  the sentinel declared.  The scan-window loop in
                        --  Infer_Column_Types still skips declared tokens
                        --  unconditionally -- that is the cliff fix itself, and
                        --  it only ever runs for a column whose type is still
                        --  undetermined (i.e. a numeric candidate).
                        Missing_Match_Count := Missing_Match_Count + 1;
                        Val := (Kind => Val_Missing);
                     elsif Col_Types (Field_Count) = Col_Integer
                        and then Try_Exact_Int (F, Exact)
                     then
                        Val := (Kind => Val_Integer, Int_Val => Exact);
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
                           Coercion_Warn_Count := Coercion_Warn_Count + 1;
                           if Coercion_Warn_Count <= Coercion_Warn_Cap then
                              SData_Core.IO.Put_Line_Error
                                 ("Warning: """ & File_Name & """, data row" &
                                  Natural'Image (Rows_Written) & ", column """ &
                                  Col_Names (Field_Count).all &
                                  """: non-numeric value """ & F &
                                  """ in numeric column -- stored as missing");
                           end if;
                           Val := (Kind => Val_Missing);
                        elsif Col_Types (Field_Count) = Col_Integer then
                           Coercion_Warn_Count := Coercion_Warn_Count + 1;
                           if Coercion_Warn_Count <= Coercion_Warn_Cap then
                              SData_Core.IO.Put_Line_Error
                                 ("Warning: """ & File_Name & """, data row" &
                                  Natural'Image (Rows_Written) & ", column """ &
                                  Col_Names (Field_Count).all &
                                  """: non-numeric value """ & F &
                                  """ in integer column -- stored as missing");
                           end if;
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
            Seen           : Name_Sets.Set;
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

            --  ADR-084: apply /TYPES= AFTER the header-suffix pass (so an
            --  explicit declaration overrides the file's own suffix, with the
            --  note Apply_Declared_Types emits) and BEFORE the scan loop (so a
            --  declared column is locked out of inference entirely).  CSV
            --  needs no new locking concept: Col_Determined is the same lock
            --  the suffix pass above already sets, now fed from a second
            --  source.
            if not Declared_List.Is_Empty then
               declare
                  Hdr_Names : Name_Vecs.Vector;
                  Types_Arr : Column_Type_Array (1 .. N_Hdr);
                  Locked    : Lock_Array (1 .. N_Hdr);
               begin
                  for I in 1 .. N_Hdr loop
                     Hdr_Names.Append
                        (To_Unbounded_String
                            (if Names_From_Header
                             then Trim (H_Str (H_Fields (I).S .. H_Fields (I).E),
                                        Ada.Strings.Both)
                             else "COL" & Trim (I'Img, Ada.Strings.Both)));
                     Types_Arr (I) := Col_Types (I);
                  end loop;
                  Apply_Declared_Types
                     (Declared_List, Hdr_Names, Types_Arr, Locked, File_Name);
                  for I in 1 .. N_Hdr loop
                     Col_Types.Replace_Element (I, Types_Arr (I));
                     if Locked (I) then
                        Col_Determined (I) := True;
                     end if;
                  end loop;
               end;
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
                              if F /= "" and then F /= "."
                                 and then not Is_Declared_Missing (Missing_Token_List, F)
                              then
                                 if not Is_Numeric_Field (F) then
                                    Col_Types.Replace_Element (I, Col_String);
                                    Col_Determined (I) := True;
                                 end if;
                                 --  ADR-0019: a numeric value leaves
                                 --  Col_Types(I) at its Col_Numeric default
                                 --  (set before this loop) and does NOT lock
                                 --  in -- keep scanning the rest of the
                                 --  window for a non-numeric value, matching
                                 --  design.md's "any non-numeric value in
                                 --  the first n rows" rule rather than the
                                 --  old first-value-wins shape.
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
                  --  ADR-084: one shared naming rule -- the final name carries
                  --  the suffix its TYPE implies.  Behavior-identical to the
                  --  append-$-if-string logic this replaces for every input
                  --  that existed before (a $-header is Col_String and keeps
                  --  its $; a %-header is Col_Integer and keeps its %), but it
                  --  also handles the case only /TYPES= can create: a DEMOTED
                  --  column, where the header says CODE$ and the declaration
                  --  says float, whose name must lose the suffix rather than
                  --  leave a numeric column called CODE$.
                  Name : constant String :=
                     Final_Column_Name (Base_Name, Col_Types (I));
               begin
                  Warn_If_Duplicate_Name (File_Name, Name, Seen);
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
            while More (Rdr) loop
               exit when Max_Rows > 0 and then Rows_Written >= Max_Rows;
               Read_Record (Rdr, Delimiter);
               if Needs_ASCII_Chk then
                  Validate_ASCII (Rdr.Recbuf (1 .. Rdr.Rec_Len));
               end if;
               Process_Line_Direct (Rdr.Recbuf (1 .. Rdr.Rec_Len));
            end loop;
         end if;

         if Coercion_Warn_Count > Coercion_Warn_Cap then
            SData_Core.IO.Put_Line_Error
               ("Warning: """ & File_Name & """:" &
                Natural'Image (Coercion_Warn_Count - Coercion_Warn_Cap) &
                " additional non-numeric-value warning(s) suppressed (" &
                Trim (Natural'Image (Coercion_Warn_Cap), Ada.Strings.Left) &
                " shown," & Natural'Image (Coercion_Warn_Count) & " total)");
         end if;

         --  sdata ADR-083 / sdata-core ADR-0026, architect §10.5: one summary
         --  line if any value matched a declared MISSING= token -- not a
         --  per-value warning (a declared token is expected, not an
         --  anomaly), but not silent either, so a mistyped or colliding
         --  token is still visible.
         if Missing_Match_Count > 0 then
            SData_Core.IO.Put_Line_Error
               ("Note: """ & File_Name & """:" &
                Natural'Image (Missing_Match_Count) &
                " value(s) matched a declared MISSING token");
         end if;

         for SA of Col_Names loop Free (SA); end loop;
         Col_Names.Clear;
      end Load_Data_Rows;

   begin
      Parse_Missing_Tokens (Missing_Tokens, Missing_Token_List);
      Parse_Declared_Types (Declared_Types, Declared_List);
      declare
         UC : constant String := To_Upper (Trim (Charset, Ada.Strings.Both));
      begin
         if UC = "UTF-16" or else UC = "UTF-16LE" then
            Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16LE,
                           All_Lines, Is_Buffered, Delimiter);
         elsif UC = "UTF-16BE" then
            Load_As_UTF16 (File_Name, Ada.Strings.UTF_Encoding.UTF_16BE,
                           All_Lines, Is_Buffered, Delimiter);
         elsif UC = "" or else UC = "AUTO" then
            Detect_And_Load (File_Name, All_Lines, Is_Buffered, Delimiter);
         elsif UC = "ASCII" then
            Needs_ASCII_Chk := True;
         end if;
      end;

      if not Is_Buffered then
         Open_File (Rdr, File_Name);
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
            if More (Rdr) then
               Read_Record (Rdr, Delimiter);
               --  ADR-0021 (PD-8): this header read was the one call site
               --  that never routed through
               --  Validate_ASCII (the Skip_Rows and NSCAN loops below both
               --  already did) -- a non-ASCII byte confined to the header
               --  row silently succeeded even under CHARSET=ASCII.  Checked
               --  on the raw line before BOM-stripping, matching the other
               --  two sites' own idiom of validating immediately after
               --  Get_Line.
               if Needs_ASCII_Chk then
                  Validate_ASCII (Rdr.Recbuf (1 .. Rdr.Rec_Len));
               end if;
               declare
                  L : constant String := Rdr.Recbuf (1 .. Rdr.Rec_Len);
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
            exit when not More (Rdr);
            Read_Record (Rdr, Delimiter);
            if Needs_ASCII_Chk then
               Validate_ASCII (Rdr.Recbuf (1 .. Rdr.Rec_Len));
            end if;
         end loop;

         while More (Rdr)
            and then Scan_Count < NSCAN
            and then (Max_Rows = 0 or else Scan_Count < Max_Rows)
         loop
            Read_Record (Rdr, Delimiter);
            if Needs_ASCII_Chk then
               Validate_ASCII (Rdr.Recbuf (1 .. Rdr.Rec_Len));
            end if;
            Scan_Count := Scan_Count + 1;
            Scan_Lines (Scan_Count) :=
               To_Unbounded_String (Rdr.Recbuf (1 .. Rdr.Rec_Len));
         end loop;
      end if;

      if Has_File_Header then
         Infer_Column_Types (To_String (Header_Line), Names_From_Header => True);
         Load_Data_Rows;
      elsif Scan_Count > 0 then
         Infer_Column_Types (To_String (Scan_Lines (1)), Names_From_Header => False);
         Load_Data_Rows;
      end if;

      Close (Rdr);
   exception
      when others =>
         Close (Rdr);
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
                        Decimals        : Integer := -1;
                        Missing_Token   : String  := "";
                        View            : SData_Core.Table.Table_View :=
                           SData_Core.Table.Default_View) is
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
      N     : constant Natural := Column_Count (View);
      D_Str : constant String := Delimiter;

      procedure Write_String (S : String) is
      begin
         if Is_UTF16 then
            String'Write (Strm,
               Ada.Strings.UTF_Encoding.Conversions.Convert
                  (S, Ada.Strings.UTF_Encoding.UTF_8, Out_Scheme));
         else
            if Is_ASCII_Chk then
               --  ADR-0021 (PD-8): raise on the first offending byte rather
               --  than warning and writing the field unconverted anyway.
               for I in S'Range loop
                  if Character'Pos (S (I)) > 127 then
                     raise SData_Core.Script_Error with
                        """" & File_Name & """: non-ASCII byte (value" &
                        Integer'Image (Character'Pos (S (I))) &
                        ") in output -- rejected (CHARSET=ASCII)";
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
               Write_String (CSV_Quote (Column_Name (I, View)));
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
         for L in 1 .. Logical_Row_Count (View) loop
            SData_Core.IO.Show_Progress ("SAVE", L);
            declare
               R : constant Positive := Logical_To_Physical (L, View);
            begin
               for C in 1 .. N loop
                  declare
                     Val : constant Value :=
                        Get_Value_Upper (R, Column_Name (C, View), View);
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
                     elsif Val.Kind = Val_Missing and then Missing_Token /= "" then
                        --  sdata ADR-083 / sdata-core ADR-0026: SAVE's
                        --  write-side MISSING= token, written verbatim (this
                        --  parameter is never split -- see Parse_CSV's own
                        --  comment on why the read side is a list and this
                        --  side is a single string).  Routed through
                        --  CSV_Quote like every other string-valued cell, so
                        --  a token that itself needs escaping (contains the
                        --  delimiter, a quote, or a newline) round-trips
                        --  correctly instead of corrupting the row.
                        Write_String (CSV_Quote (Missing_Token));
                     end if;
                  end;
                  if C /= N then
                     Write_String (D_Str);
                  end if;
               end loop;
            end;
            Write_String (EOL);
         end loop;
         SData_Core.IO.Show_Progress ("SAVE", Logical_Row_Count (View), Final => True);
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