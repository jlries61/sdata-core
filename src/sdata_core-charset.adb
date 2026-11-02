--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Interfaces.C;
with Interfaces.C.Strings;
with System;                 use System;

package body SData_Core.Charset is

   use type Interfaces.C.size_t;

   Initial_Output_Factor : constant := 2;    --  first output buffer: 2 x input
   Output_Slack          : constant := 16;   --  ... plus room for a shift sequence

   --  Status codes returned by sdata_iconv_convert (see sdata_iconv.c).
   Conv_OK         : constant := 0;   --  converted; the output is complete
   Conv_Invalid    : constant := 1;   --  invalid or unrepresentable input
   Conv_Incomplete : constant := 2;   --  input ends inside a character
   Conv_No_Room    : constant := 3;   --  output buffer too small: retry bigger

   function C_Open (To_Code, From_Code : Interfaces.C.Strings.chars_ptr)
      return System.Address
   with Import, Convention => C, External_Name => "sdata_iconv_open";

   procedure C_Close (CD : System.Address)
   with Import, Convention => C, External_Name => "sdata_iconv_close";

   function C_Convert
     (CD      : System.Address;
      Input   : System.Address;
      In_Len  : Interfaces.C.size_t;
      Output  : System.Address;
      Out_Cap : Interfaces.C.size_t;
      Out_Len : access Interfaces.C.size_t;
      In_Used : access Interfaces.C.size_t) return Interfaces.C.int
   with Import, Convention => C, External_Name => "sdata_iconv_convert";

   function Canonical (Name : String) return String is
     (Ada.Characters.Handling.To_Upper
        (Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both)));

   function Is_UTF8 (Name : String) return Boolean is
      UC : constant String := Canonical (Name);
   begin
      return UC = "" or else UC = "AUTO" or else UC = "UTF-8"
        or else UC = "UTF8";
   end Is_UTF8;

   function Open_Descriptor (To_Code, From_Code : String) return System.Address
   is
      T : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (To_Code);
      F : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (From_Code);
      CD : constant System.Address := C_Open (T, F);
   begin
      Interfaces.C.Strings.Free (T);
      Interfaces.C.Strings.Free (F);
      return CD;
   end Open_Descriptor;

   function Is_Supported (Name : String) return Boolean is
   begin
      if Is_UTF8 (Name) then
         return True;
      end if;
      declare
         CD : constant System.Address := Open_Descriptor ("UTF-8", Canonical (Name));
      begin
         if CD = System.Null_Address then
            return False;
         end if;
         C_Close (CD);
         return True;
      end;
   end Is_Supported;

   --  UTF-8 byte classes (RFC 3629).  A character is a lead byte followed by
   --  continuation bytes; the lead byte's range gives the length.
   Last_ASCII         : constant := 16#7F#;   --  one-byte characters: 0 .. 7F
   First_Continuation : constant := 16#80#;   --  10xxxxxx
   Last_Continuation  : constant := 16#BF#;
   First_Lead_2       : constant := 16#C2#;   --  C0 and C1 would be overlong
   Last_Lead_2        : constant := 16#DF#;
   First_Lead_3       : constant := 16#E0#;
   Last_Lead_3        : constant := 16#EF#;
   First_Lead_4       : constant := 16#F0#;
   Last_Lead_4        : constant := 16#F4#;   --  F5 and up exceed U+10FFFF

   --  The second byte is narrower after some lead bytes, to rule out
   --  overlong forms (E0, F0), surrogates (ED) and values above U+10FFFF (F4).
   Lead_No_Overlong_3 : constant := 16#E0#;   --  second byte >= A0
   Min_Second_After_E0 : constant := 16#A0#;
   Lead_Surrogates    : constant := 16#ED#;   --  second byte <= 9F
   Max_Second_After_ED : constant := 16#9F#;
   Lead_No_Overlong_4 : constant := 16#F0#;   --  second byte >= 90
   Min_Second_After_F0 : constant := 16#90#;
   Lead_Max_Plane     : constant := 16#F4#;   --  second byte <= 8F
   Max_Second_After_F4 : constant := 16#8F#;

   --  Length of the UTF-8 sequence introduced by lead byte B, or 0 if B
   --  cannot start one.
   function Seq_Length (B : Natural) return Natural is
     (if B <= Last_ASCII then 1
      elsif B in First_Lead_2 .. Last_Lead_2 then 2
      elsif B in First_Lead_3 .. Last_Lead_3 then 3
      elsif B in First_Lead_4 .. Last_Lead_4 then 4
      else 0);

   --  Offset (1-based) of the first invalid byte of S, or 0 when S is
   --  well-formed UTF-8 (no overlongs, no surrogates, nothing above U+10FFFF).
   function First_Invalid_UTF8 (S : String) return Natural is
      I : Positive := S'First;
   begin
      while I <= S'Last loop
         declare
            B0 : constant Natural := Character'Pos (S (I));
            N  : constant Natural := Seq_Length (B0);
         begin
            if N = 0 or else I + N - 1 > S'Last then
               return I;
            end if;
            for K in 1 .. N - 1 loop
               if Character'Pos (S (I + K))
                  not in First_Continuation .. Last_Continuation
               then
                  return I;
               end if;
            end loop;
            if N >= 3 then
               declare
                  B1 : constant Natural := Character'Pos (S (I + 1));
               begin
                  if (B0 = Lead_No_Overlong_3 and then B1 < Min_Second_After_E0)
                    or else (B0 = Lead_Surrogates and then B1 > Max_Second_After_ED)
                    or else (B0 = Lead_No_Overlong_4 and then B1 < Min_Second_After_F0)
                    or else (B0 = Lead_Max_Plane and then B1 > Max_Second_After_F4)
                  then
                     return I;
                  end if;
               end;
            end if;
            I := I + N;
         end;
      end loop;
      return 0;
   end First_Invalid_UTF8;

   function Incomplete_Tail (S : String) return Natural is
   begin
      --  Look back over at most the last three bytes for a lead byte whose
      --  character does not fit in what remains.
      for Back in 0 .. Natural'Min (2, S'Length - 1) loop
         declare
            B : constant Natural := Character'Pos (S (S'Last - Back));
            N : constant Natural := Seq_Length (B);
         begin
            if N >= 2 then
               return (if Back + 1 < N then Back + 1 else 0);
            elsif N = 1 then
               return 0;         --  an ASCII byte ends any earlier character
            end if;               --  otherwise a continuation byte: keep going
         end;
      end loop;
      return 0;
   end Incomplete_Tail;

   function Valid_UTF8 (S : String) return Boolean is
     (First_Invalid_UTF8 (S) = 0);

   procedure Convert_Buffer
     (CD      : System.Address;
      Input   : String;
      Out_Str : out GNAT.Strings.String_Access;
      In_Used : out Natural;
      Status  : out Integer);

   procedure Open (Conv : in out Converter; Name : String) is
      Ext : constant String := Canonical (Name);
   begin
      Finalize (Conv);
      Conv.To_UTF8_CD   := Open_Descriptor ("UTF-8", Ext);
      Conv.From_UTF8_CD := Open_Descriptor (Ext, "UTF-8");
      if Conv.To_UTF8_CD = System.Null_Address
        or else Conv.From_UTF8_CD = System.Null_Address
      then
         Finalize (Conv);
         raise SData_Core.Script_Error with
            "unsupported character set """ & Name
            & """ (see ""iconv -l"" for the names this system knows)";
      end if;
      Conv.Name := To_Unbounded_String (Ext);
      Conv.Pre  := Null_Unbounded_String;
      --  Probe for a byte-order mark emitted on every conversion: it is
      --  what "A" yields beyond one character's worth of bytes.
      declare
         One, Two : GNAT.Strings.String_Access;
         Used     : Natural;
         S1, S2   : Integer;
      begin
         Convert_Buffer (Conv.From_UTF8_CD, "A",  One, Used, S1);
         Convert_Buffer (Conv.From_UTF8_CD, "AB", Two, Used, S2);
         if S1 = Conv_OK and then S2 = Conv_OK then
            declare
               Unit : constant Integer := Two'Length - One'Length;
               Pre  : constant Integer := One'Length - Unit;
            begin
               if Unit > 0 and then Pre > 0
                 and then Two (Two'First .. Two'First + Pre - 1)
                          = One (One'First .. One'First + Pre - 1)
               then
                  Conv.Pre := To_Unbounded_String
                     (One (One'First .. One'First + Pre - 1));
               end if;
            end;
         end if;
         GNAT.Strings.Free (One);
         GNAT.Strings.Free (Two);
      end;
   end Open;

   function Preamble (Conv : Converter) return String is
     (To_String (Conv.Pre));

   overriding procedure Finalize (Conv : in out Converter) is
   begin
      if Conv.To_UTF8_CD /= System.Null_Address then
         C_Close (Conv.To_UTF8_CD);
         Conv.To_UTF8_CD := System.Null_Address;
      end if;
      if Conv.From_UTF8_CD /= System.Null_Address then
         C_Close (Conv.From_UTF8_CD);
         Conv.From_UTF8_CD := System.Null_Address;
      end if;
   end Finalize;

   --  One whole-buffer conversion.  Status as documented in sdata_iconv.c;
   --  Out receives the bytes produced so far (also on status 1 and 2).
   --  Out_Str is allocated on the heap (the input may be a whole file) and
   --  holds exactly the bytes produced; the caller frees it.
   procedure Convert_Buffer
     (CD      : System.Address;
      Input   : String;
      Out_Str : out GNAT.Strings.String_Access;
      In_Used : out Natural;
      Status  : out Integer)
   is
      --  A first guess; sdata_iconv_convert reports Conv_No_Room when the
      --  output (UTF-32 is four bytes per ASCII byte) does not fit, and the
      --  buffer is doubled.
      Capacity : Natural := Initial_Output_Factor * Input'Length + Output_Slack;
      Buf      : GNAT.Strings.String_Access;
   begin
      loop
         Buf := new String (1 .. Capacity);
         declare
            Out_Len  : aliased Interfaces.C.size_t := 0;
            Used     : aliased Interfaces.C.size_t := 0;
            Rc       : constant Interfaces.C.int :=
               C_Convert (CD, Input'Address,
                          Interfaces.C.size_t (Input'Length),
                          Buf.all'Address, Interfaces.C.size_t (Capacity),
                          Out_Len'Access, Used'Access);
         begin
            Status := Integer (Rc);
            if Status = Conv_No_Room then
               GNAT.Strings.Free (Buf);
               Capacity := Capacity * 2;
            else
               Out_Str := new String'(Buf (1 .. Natural (Out_Len)));
               GNAT.Strings.Free (Buf);
               In_Used := Natural (Used);
               return;
            end if;
         end;
      end loop;
   end Convert_Buffer;

   function Describe (Name : Unbounded_String) return String is
     (To_String (Name));

   procedure To_UTF8
     (Conv    : Converter;
      Raw     : String;
      Context : String;
      Result  : out GNAT.Strings.String_Access)
   is
      Used    : Natural;
      Status  : Integer;
   begin
      Convert_Buffer (Conv.To_UTF8_CD, Raw, Result, Used, Status);
      case Status is
         when Conv_OK =>
            return;
         when Conv_Invalid | Conv_Incomplete =>
            GNAT.Strings.Free (Result);
            raise SData_Core.Script_Error with
               Context & ": byte" & Integer'Image (Raw'First + Used)
               & " is not valid " & Describe (Conv.Name) & " text";
         when others =>
            GNAT.Strings.Free (Result);
            raise SData_Core.Script_Error with
               Context & ": cannot convert from " & Describe (Conv.Name);
      end case;
   end To_UTF8;

   function To_UTF8
     (Conv : Converter; Raw : String; Context : String) return String
   is
      Result : GNAT.Strings.String_Access;
   begin
      To_UTF8 (Conv, Raw, Context, Result);
      declare
         S : constant String := Result.all;
      begin
         GNAT.Strings.Free (Result);
         return S;
      end;
   end To_UTF8;

   --  "U+20AC" for the UTF-8 character starting at Text (At).
   function Code_Point_Image (Text : String; At_Byte : Positive) return String is
      Hex  : constant String := "0123456789ABCDEF";
      N    : constant Natural := Seq_Length (Character'Pos (Text (At_Byte)));
      CP   : Natural := 0;
      Img  : String (1 .. 8);
      Pos  : Natural := Img'Last;
   begin
      if N <= 1 or else At_Byte + N - 1 > Text'Last then
         return "byte" & Integer'Image (At_Byte);
      end if;
      CP := Character'Pos (Text (At_Byte)) mod (2 ** (7 - N));
      for K in 1 .. N - 1 loop
         CP := CP * 64 + Character'Pos (Text (At_Byte + K)) mod 64;
      end loop;
      while CP > 0 or else Pos > Img'Last - 3 loop
         Img (Pos) := Hex (CP mod 16 + 1);
         CP := CP / 16;
         Pos := Pos - 1;
      end loop;
      return "U+" & Img (Pos + 1 .. Img'Last);
   end Code_Point_Image;

   function From_UTF8
     (Conv    : Converter;
      Text    : String;
      Context : String;
      Strict  : Boolean := True) return String
   is
      Result : Unbounded_String;
      Pos    : Positive := Text'First;
   begin
      while Pos <= Text'Last loop
         declare
            Piece  : GNAT.Strings.String_Access;
            Used   : Natural;
            Status : Integer;
         begin
            Convert_Buffer (Conv.From_UTF8_CD, Text (Pos .. Text'Last),
                            Piece, Used, Status);
            declare
               Pre : constant String := To_String (Conv.Pre);
            begin
               if Pre'Length > 0 and then Piece'Length >= Pre'Length
                 and then Piece (Piece'First .. Piece'First + Pre'Length - 1) = Pre
               then
                  Append (Result, Piece (Piece'First + Pre'Length .. Piece'Last));
               else
                  Append (Result, Piece.all);
               end if;
            end;
            GNAT.Strings.Free (Piece);
            case Status is
               when Conv_OK =>
                  return To_String (Result);
               when Conv_Invalid | Conv_Incomplete =>
                  if Strict then
                     raise SData_Core.Script_Error with
                        Context & ": character " & Code_Point_Image (Text, Pos + Used)
                        & " cannot be written in " & Describe (Conv.Name);
                  end if;
                  --  Not strict: '?' for the offending character, then go on.
                  Append (Result, '?');
                  declare
                     At_Byte : constant Positive := Pos + Used;
                     N       : constant Natural :=
                        Natural'Max (1, Seq_Length (Character'Pos (Text (At_Byte))));
                  begin
                     Pos := Natural'Min (At_Byte + N, Text'Last + 1);
                  end;
               when others =>
                  raise SData_Core.Script_Error with
                     Context & ": cannot convert to " & Describe (Conv.Name);
            end case;
         end;
      end loop;
      return To_String (Result);
   end From_UTF8;

end SData_Core.Charset;
