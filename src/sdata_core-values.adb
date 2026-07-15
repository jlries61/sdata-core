--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Text_IO;
with SData_Core.Config;
with Ada.Strings.Fixed;     use Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body SData_Core.Values is

   --------------
   -- Is_Inf --
   --------------
   function Is_Inf (F : Real) return Boolean is
   begin
      return F > Real'Last or else F < Real'First;
   end Is_Inf;

   -------------------
   -- Convert_Value --
   -------------------
   function Convert_Value (V : Value; Target : Value_Kind) return Value is
   begin
      if V.Kind = Val_Missing or else V.Kind = Target then
         return V;
      end if;
      case Target is
         when Val_Numeric =>
            if V.Kind = Val_Integer then
               return (Kind => Val_Numeric, Num_Val => Real (V.Int_Val));
            end if;
            raise Conversion_Error
              with "cannot convert string value to numeric";
         when Val_Integer =>
            if V.Kind = Val_Numeric then
               return (Kind    => Val_Integer,
                       Int_Val => Integer (Real'Truncation (V.Num_Val)));
            end if;
            raise Conversion_Error
              with "cannot convert string value to integer";
         when Val_String =>
            raise Conversion_Error
              with "cannot convert numeric value to string";
         when Val_Missing =>
            return (Kind => Val_Missing);
      end case;
   end Convert_Value;

   ------------------
   -- To_String --
   ------------------
   function To_String (V : Value) return String is
   begin
      case V.Kind is
         when Val_Numeric =>
            if Is_Inf (V.Num_Val) then
               return (if V.Num_Val > 0.0 then "Inf" else "-Inf");
            end if;
            declare
               Img : constant String := Real'Image (V.Num_Val);
            begin
               return Trim (Img, Ada.Strings.Both);
            end;
         when Val_Integer =>
            declare
               Img : constant String := Integer'Image (V.Int_Val);
            begin
               return Trim (Img, Ada.Strings.Both);
            end;
         when Val_String =>
            return To_String (V.Str_Val);
         when Val_Missing =>
            return ".";
      end case;
   end To_String;

   -------------------------
   -- To_String_Formatted --
   -------------------------
   function To_String_Formatted (V : Value) return String is
   begin
      case V.Kind is
         when Val_Numeric =>
            if Is_Inf (V.Num_Val) then
               return (if V.Num_Val > 0.0 then "Inf" else "-Inf");
            end if;
            declare
               package Float_IO is new Ada.Text_IO.Float_IO (Real);
               Img : String (1 .. 100);
               Aft_Count : constant Natural := SData_Core.Config.Print_Digits;
            begin
               if V.Num_Val = 0.0 then
                  declare
                     Zero_Img : String (1 .. Aft_Count + 2);
                  begin
                     Zero_Img (1 .. 2) := "0.";
                     for I in 3 .. Zero_Img'Last loop
                        Zero_Img (I) := '0';
                     end loop;
                     return Zero_Img;
                  end;
               end if;
               Float_IO.Put (Img, V.Num_Val, Aft => Aft_Count, Exp => 0);
               return Trim (Img, Ada.Strings.Both);
            exception
               when others =>
                  return Trim (Real'Image (V.Num_Val), Ada.Strings.Both);
            end;
         when others => return To_String (V);
      end case;
   end To_String_Formatted;

   --  Strip trailing zeros in the fractional part and a trailing bare '.'.
   --  Strings with no '.', or any exponent ('E'/'e'), are returned unchanged.
   function Trim_Trailing_Zeros (S : String) return String is
      Has_Dot : Boolean := False;
   begin
      for Ch of S loop
         if Ch = 'E' or else Ch = 'e' then
            return S;
         elsif Ch = '.' then
            Has_Dot := True;
         end if;
      end loop;
      if not Has_Dot then
         return S;
      end if;
      declare
         Last : Integer := S'Last;
      begin
         while Last >= S'First and then S (Last) = '0' loop
            Last := Last - 1;
         end loop;
         if Last >= S'First and then S (Last) = '.' then
            Last := Last - 1;
         end if;
         return S (S'First .. Last);
      end;
   end Trim_Trailing_Zeros;

   -----------------------
   -- Image_Round_Trip --
   -----------------------
   function Image_Round_Trip (X : Real) return String is
      package Float_IO is new Ada.Text_IO.Float_IO (Real);
      Buf : String (1 .. 128);
   begin
      if Is_Inf (X) then
         return (if X > 0.0 then "Inf" else "-Inf");
      end if;
      if X = 0.0 then
         return "0";
      end if;
      --  Integer-valued fast path (also avoids Aft=0 in Float_IO.Put).
      declare
         R : constant Real := Real'Rounding (X);
      begin
         if R = X and then abs R < Real (Integer'Last) then
            return Trim (Integer'Image (Integer (R)), Ada.Strings.Both);
         end if;
      end;
      --  Shortest fixed-notation form (Aft >= 1) that reads back exactly.
      for Aft in 1 .. 17 loop
         begin
            Float_IO.Put (Buf, X, Aft => Aft, Exp => 0);
            declare
               S : constant String := Trim (Buf, Ada.Strings.Both);
            begin
               if Real'Value (S) = X then
                  return Trim_Trailing_Zeros (S);
               end if;
            end;
         exception
            when others => null;  --  field overflow etc.; try next Aft
         end;
      end loop;
      --  Fallback: exponential, 17 significant digits (double round-trip).
      Float_IO.Put (Buf, X, Aft => 16, Exp => 2);
      return Trim (Buf, Ada.Strings.Both);
   exception
      --  Safety net for NaN (and any other value that slips past every
      --  guard above, including the Aft => 1 .. 17 per-iteration handler):
      --  the unguarded exponential fallback's Float_IO.Put is not proven
      --  exception-free for every special value on every platform/compiler.
      --  Mirrors the To_String_Formatted pattern so a SAVE never crashes on
      --  a NaN cell (reachable via OPTIONS IEEE_DIVIDE YES; +Inf/-Inf are
      --  already handled by Is_Inf above, and Real'Image renders NaN as
      --  "NAN").
      when others =>
         return Trim (Real'Image (X), Ada.Strings.Both);
   end Image_Round_Trip;

   --------------------------
   -- Image_Fixed_Decimals --
   --------------------------
   function Image_Fixed_Decimals (X : Real; Decimals : Natural) return String is
      package Float_IO is new Ada.Text_IO.Float_IO (Real);
      Buf : String (1 .. 128);
   begin
      if Is_Inf (X) then
         return (if X > 0.0 then "Inf" else "-Inf");
      end if;
      if Decimals = 0 then
         declare
            R : constant Real := Real'Rounding (X);
         begin
            if abs R < Real (Integer'Last) then
               return Trim (Integer'Image (Integer (R)), Ada.Strings.Both);
            else
               return Image_Round_Trip (R);
            end if;
         end;
      end if;
      begin
         Float_IO.Put (Buf, X, Aft => Decimals, Exp => 0);
         return Trim_Trailing_Zeros (Trim (Buf, Ada.Strings.Both));
      exception
         when others =>
            --  Aft > Field'Last (255) or other Put failure: more decimals than
            --  the value's precision -> the round-trip form is the exact value.
            return Image_Round_Trip (X);
      end;
   end Image_Fixed_Decimals;

   -------------
   -- Is_True --
   -------------
   function Is_True (V : Value) return Boolean is
   begin
      case V.Kind is
         when Val_Numeric =>
            return V.Num_Val /= 0.0;
         when Val_Integer =>
            return V.Int_Val /= 0;
         when Val_String =>
            return Length (V.Str_Val) > 0;
         when others =>
            return False;
      end case;
   end Is_True;

   ---------
   -- "=" --
   ---------
   overriding function "=" (L, R : Value) return Boolean is
   begin
      if L.Kind /= R.Kind then
         --  Promotion logic for comparison
         if L.Kind = Val_Numeric and then R.Kind = Val_Integer then
            return L.Num_Val = Real (R.Int_Val);
         elsif L.Kind = Val_Integer and then R.Kind = Val_Numeric then
            return Real (L.Int_Val) = R.Num_Val;
         end if;
         return False;
      end if;

      case L.Kind is
         when Val_Numeric => return L.Num_Val = R.Num_Val;
         when Val_Integer => return L.Int_Val = R.Int_Val;
         when Val_String  =>
            return L.Str_Val = R.Str_Val;
         when Val_Missing => return True;
      end case;
   end "=";

   ---------
   -- "<" --
   ---------
   function "<" (L, R : Value) return Boolean is
   begin
      --  Missing is always smallest
      if L.Kind = Val_Missing then
         return R.Kind /= Val_Missing;
      elsif R.Kind = Val_Missing then
         return False;
      end if;

      if L.Kind = Val_Numeric or else L.Kind = Val_Integer then
         declare
            FL : constant Real :=
               (if L.Kind = Val_Numeric then L.Num_Val else Real (L.Int_Val));
         begin
            if R.Kind = Val_Numeric or else R.Kind = Val_Integer then
               declare
                  --  FR is only safe to compute once R is known to be
                  --  Numeric or Integer; computing it earlier would fail
                  --  the discriminant check for R = String.
                  FR : constant Real :=
                     (if R.Kind = Val_Numeric then R.Num_Val
                                              else Real (R.Int_Val));
               begin
                  return FL < FR;
               end;
            else
               return True; -- Numeric < String (arbitrary but consistent)
            end if;
         end;
      elsif L.Kind = Val_String then
         if R.Kind = Val_String then
            return L.Str_Val < R.Str_Val;
         else
            return False; -- String > Numeric
         end if;
      end if;
      return False;
   end "<";

begin
   --  Real'Last * 2.0 must be computed at runtime to avoid the
   --  static-expression Constraint_Error GNAT raises at compile time.
   --  Big cannot be constant for the same reason; suppress the spurious warning.
   --  Validity checks are disabled project-wide via -gnatVn (see sdata_core.gpr)
   --  because this package legitimately stores IEEE 754 infinity in float vars.
   declare
      pragma Warnings (Off, "could be declared constant");
      Big : Real := Real'Last;
      pragma Warnings (On, "could be declared constant");
   begin
      Pos_Inf :=  Big * 2.0;
      Neg_Inf := -(Big * 2.0);
   end;
end SData_Core.Values;