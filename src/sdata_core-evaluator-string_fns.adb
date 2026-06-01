--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with SData_Core.Values; use SData_Core.Values;

package body SData_Core.Evaluator.String_Fns is

   function To_Base_String (N : Integer; Radix : Positive) return String is
      Digits_Map : constant String := "0123456789ABCDEF";
      Buf        : String (1 .. 32);
      Len        : Natural := 0;
      Val        : Integer := abs N;
   begin
      if Val = 0 then return "0"; end if;
      while Val > 0 loop
         Len := Len + 1;
         Buf (Len) := Digits_Map (Val mod Radix + 1);
         Val := Val / Radix;
      end loop;
      for I in 1 .. Len / 2 loop
         declare Tmp : constant Character := Buf (I);
         begin Buf (I) := Buf (Len - I + 1); Buf (Len - I + 1) := Tmp; end;
      end loop;
      return Buf (1 .. Len);
   end To_Base_String;

   ---------------------------------------------------------------------------
   --  String handlers
   ---------------------------------------------------------------------------

   function Handle_Len (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Value := Vals.Element (1);
      begin
         if V.Kind = Val_String then
            return (Kind => Val_Integer, Int_Val => Length (V.Str_Val));
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Handle_Len;

   function Handle_Left (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         V : constant Value   := Vals.Element (1);
         N : constant Integer := Integer (Convert_To_Float (Vals.Element (2)));
         R : Value (Val_String);
      begin
         if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
         if N <= 0 then R.Str_Val := Null_Unbounded_String;
         elsif N >= Length (V.Str_Val) then R.Str_Val := V.Str_Val;
         else R.Str_Val := To_Unbounded_String (Slice (V.Str_Val, 1, N));
         end if;
         return R;
      end;
   end Handle_Left;

   function Handle_Right (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         V     : constant Value   := Vals.Element (1);
         N     : constant Integer := Integer (Convert_To_Float (Vals.Element (2)));
         R     : Value (Val_String);
         Start : Integer;
      begin
         if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
         if N <= 0 then R.Str_Val := Null_Unbounded_String;
         elsif N >= Length (V.Str_Val) then R.Str_Val := V.Str_Val;
         else
            Start := Length (V.Str_Val) - N + 1;
            R.Str_Val := To_Unbounded_String (Slice (V.Str_Val, Start, Length (V.Str_Val)));
         end if;
         return R;
      end;
   end Handle_Right;

   function Handle_Mid (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         V     : constant Value   := Vals.Element (1);
         Start : constant Integer := Integer (Convert_To_Float (Vals.Element (2)));
         Len   : constant Integer :=
            (if Has_Args (Vals, 3) then Integer (Convert_To_Float (Vals.Element (3)))
             else Length (V.Str_Val));
         R     : Value (Val_String);
         S, E  : Integer;
      begin
         if V.Kind /= Val_String or else Start < 1 then return (Kind => Val_Missing); end if;
         S := Start;
         E := Integer'Min (S + Len - 1, Length (V.Str_Val));
         if S > Length (V.Str_Val) then R.Str_Val := Null_Unbounded_String;
         else R.Str_Val := To_Unbounded_String (Slice (V.Str_Val, S, E));
         end if;
         return R;
      end;
   end Handle_Mid;

   function Handle_Seg (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      declare
         V     : constant Value   := Vals.Element (1);
         Start : Integer          := Integer (Convert_To_Float (Vals.Element (2)));
         Len   : constant Integer := Integer (Convert_To_Float (Vals.Element (3)));
         R     : Value (Val_String);
         S, E  : Integer;
      begin
         if V.Kind /= Val_String or else Len <= 0 then return (Kind => Val_Missing); end if;
         if Start <= 0 then Start := 1; end if;
         S := Start;
         E := Integer'Min (S + Len - 1, Length (V.Str_Val));
         if S > Length (V.Str_Val) then R.Str_Val := Null_Unbounded_String;
         else R.Str_Val := To_Unbounded_String (Slice (V.Str_Val, S, E));
         end if;
         return R;
      end;
   end Handle_Seg;

   function Handle_Trim (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      V : Value;
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      V := Vals.Element (1);
      if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
      declare use Ada.Strings.Fixed;
      begin R.Str_Val := To_Unbounded_String (Trim (To_String (V.Str_Val), Ada.Strings.Both)); end;
      return R;
   end Handle_Trim;

   function Handle_Ltrim (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      V : Value;
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      V := Vals.Element (1);
      if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
      declare use Ada.Strings.Fixed;
      begin R.Str_Val := To_Unbounded_String (Trim (To_String (V.Str_Val), Ada.Strings.Left)); end;
      return R;
   end Handle_Ltrim;

   function Handle_Rtrim (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      V : Value;
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      V := Vals.Element (1);
      if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
      declare use Ada.Strings.Fixed;
      begin R.Str_Val := To_Unbounded_String (Trim (To_String (V.Str_Val), Ada.Strings.Right)); end;
      return R;
   end Handle_Rtrim;

   function Handle_ASCII (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Value := Vals.Element (1);
      begin
         if V.Kind /= Val_String or else Length (V.Str_Val) = 0 then
            return (Kind => Val_Missing);
         end if;
         return (Kind => Val_Integer, Int_Val => Character'Pos (Element (V.Str_Val, 1)));
      end;
   end Handle_ASCII;

   function Handle_Upper (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      V : Value;
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      V := Vals.Element (1);
      if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String (To_Upper (SData_Core.Values.To_String (V)));
      return R;
   end Handle_Upper;

   function Handle_Lower (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      V : Value;
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      V := Vals.Element (1);
      if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String (To_Lower (SData_Core.Values.To_String (V)));
      return R;
   end Handle_Lower;

   function Handle_Pos (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         Needle   : constant Value := Vals.Element (1);
         Haystack : constant Value := Vals.Element (2);
         Start_V  : constant Value := (if Has_Args (Vals, 3) then Vals.Element (3) else (Kind => Val_Integer, Int_Val => 1));
         From     : constant Positive := Positive'Max (Integer (Convert_To_Float (Start_V)), 1);
      begin
         if Needle.Kind /= Val_String or else Haystack.Kind /= Val_String then
            return (Kind => Val_Missing);
         end if;
         if Length (Needle.Str_Val) = 0 then return (Kind => Val_Integer, Int_Val => From); end if;
         if From > Length (Haystack.Str_Val) then return (Kind => Val_Integer, Int_Val => 0); end if;
         return (Kind    => Val_Integer,
                 Int_Val => Index (Haystack.Str_Val, SData_Core.Values.To_String (Needle), From));
      end;
   end Handle_Pos;

   function Handle_Instr (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         Start_Pos : Positive := 1;
         H_Idx     : Positive := 1;
         N_Idx     : Positive := 2;
      begin
         if Has_Args (Vals, 3) then
            Start_Pos := Positive'Max (Integer (Convert_To_Float (Vals.Element (1))), 1);
            H_Idx := 2;
            N_Idx := 3;
         end if;
         declare
            Haystack : constant Value := Vals.Element (H_Idx);
            Needle   : constant Value := Vals.Element (N_Idx);
         begin
            if Needle.Kind /= Val_String or else Haystack.Kind /= Val_String then
               return (Kind => Val_Missing);
            end if;
            if Length (Needle.Str_Val) = 0 then return (Kind => Val_Integer, Int_Val => Start_Pos); end if;
            if Start_Pos > Length (Haystack.Str_Val) then return (Kind => Val_Integer, Int_Val => 0); end if;
            return (Kind    => Val_Integer,
                    Int_Val => Index (Haystack.Str_Val, SData_Core.Values.To_String (Needle), Start_Pos));
         end;
      end;
   end Handle_Instr;

   function Handle_Chr (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare Code : constant Integer := Integer (Convert_To_Float (Vals.Element (1)));
      begin
         R.Str_Val := To_Unbounded_String ("" & Character'Val (Code));
         return R;
      end;
   end Handle_Chr;

   function Handle_Str (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String (SData_Core.Values.To_String_Formatted (Vals.Element (1)));
      return R;
   end Handle_Str;

   function Handle_Val (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Value := Vals.Element (1);
      begin
         if V.Kind /= Val_String then return (Kind => Val_Missing); end if;
         begin
            return (Kind    => Val_Numeric,
                    Num_Val => Float'Value (SData_Core.Values.To_String (V)));
         exception
            when Constraint_Error => return (Kind => Val_Missing);
         end;
      end;
   end Handle_Val;

   function Handle_Num_Str (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      Result : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      Result.Str_Val :=
         To_Unbounded_String (SData_Core.Values.To_String_Formatted (Vals.Element (1)));
      return Result;
   end Handle_Num_Str;

   function Handle_Hex (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String
         (To_Base_String (Integer (Convert_To_Float (Vals.Element (1))), 16));
      return R;
   end Handle_Hex;

   function Handle_Hex_From_Str (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         V : constant Value := Vals.Element (1);
         S : constant String := (if V.Kind = Val_String then To_String (V.Str_Val)
                                 else Integer'Image (Integer (Convert_To_Float (V))));
      begin
         return (Kind => Val_Integer, Int_Val => Integer'Value ("16#" & S & "#"));
      exception
         when Constraint_Error => return (Kind => Val_Missing);
      end;
   end Handle_Hex_From_Str;

   function Handle_Oct (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String
         (To_Base_String (Integer (Convert_To_Float (Vals.Element (1))), 8));
      return R;
   end Handle_Oct;

   function Handle_Bin (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : Value (Val_String);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      R.Str_Val := To_Unbounded_String
         (To_Base_String (Integer (Convert_To_Float (Vals.Element (1))), 2));
      return R;
   end Handle_Bin;

   ---------------------------------------------------------------------------

   procedure Register is
   begin
      Dispatch_Table.Insert ("LEN",    Handle_Len'Access);
      Dispatch_Table.Insert ("LEFT$",  Handle_Left'Access);
      Dispatch_Table.Insert ("RIGHT$", Handle_Right'Access);
      Dispatch_Table.Insert ("MID$",   Handle_Mid'Access);
      Dispatch_Table.Insert ("SEG$",   Handle_Seg'Access);
      Dispatch_Table.Insert ("TRIM$",  Handle_Trim'Access);
      Dispatch_Table.Insert ("LTRIM$", Handle_Ltrim'Access);
      Dispatch_Table.Insert ("RTRIM$", Handle_Rtrim'Access);
      Dispatch_Table.Insert ("ASCII",  Handle_ASCII'Access);
      Dispatch_Table.Insert ("ASC",    Handle_ASCII'Access);
      Dispatch_Table.Insert ("UCASE$", Handle_Upper'Access);
      Dispatch_Table.Insert ("UPPER$", Handle_Upper'Access);
      Dispatch_Table.Insert ("LCASE$", Handle_Lower'Access);
      Dispatch_Table.Insert ("LOWER$", Handle_Lower'Access);
      Dispatch_Table.Insert ("POS",    Handle_Pos'Access);
      Dispatch_Table.Insert ("INSTR",  Handle_Instr'Access);
      Dispatch_Table.Insert ("CHR$",   Handle_Chr'Access);
      Dispatch_Table.Insert ("STR$",   Handle_Str'Access);
      Dispatch_Table.Insert ("VAL",    Handle_Val'Access);
      Dispatch_Table.Insert ("HEX$",   Handle_Hex'Access);
      Dispatch_Table.Insert ("HEX",    Handle_Hex_From_Str'Access);
      Dispatch_Table.Insert ("OCT$",   Handle_Oct'Access);
      Dispatch_Table.Insert ("BIN$",   Handle_Bin'Access);
      Dispatch_Table.Insert ("NUM$",   Handle_Num_Str'Access);
   end Register;

begin
   Register;
end SData_Core.Evaluator.String_Fns;