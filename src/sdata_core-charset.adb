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

   --  Length of the UTF-8 sequence introduced by lead byte B, or 0 if B
   --  cannot start one.
   function Seq_Length (B : Natural) return Natural is
     (if B < 16#80# then 1
      elsif B in 16#C2# .. 16#DF# then 2
      elsif B in 16#E0# .. 16#EF# then 3
      elsif B in 16#F0# .. 16#F4# then 4
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
               if Character'Pos (S (I + K)) not in 16#80# .. 16#BF# then
                  return I;
               end if;
            end loop;
            if N >= 3 then
               declare
                  B1 : constant Natural := Character'Pos (S (I + 1));
               begin
                  if (B0 = 16#E0# and then B1 < 16#A0#)
                    or else (B0 = 16#ED# and then B1 > 16#9F#)
                    or else (B0 = 16#F0# and then B1 < 16#90#)
                    or else (B0 = 16#F4# and then B1 > 16#8F#)
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

   function Valid_UTF8 (S : String) return Boolean is
     (First_Invalid_UTF8 (S) = 0);

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
   end Open;

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
      Capacity : Natural := 2 * Input'Length + 16;
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
            if Status = 3 then
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
         when 0 =>
            return;
         when 1 | 2 =>
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
            Append (Result, Piece.all);
            GNAT.Strings.Free (Piece);
            case Status is
               when 0 =>
                  return To_String (Result);
               when 1 | 2 =>
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
