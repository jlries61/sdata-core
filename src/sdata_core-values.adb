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
   function Is_Inf (F : Float) return Boolean is
   begin
      return F > Float'Last or else F < Float'First;
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
               return (Kind => Val_Numeric, Num_Val => Float (V.Int_Val));
            end if;
            raise SData_Core.Script_Error
              with "cannot convert string value to numeric";
         when Val_Integer =>
            if V.Kind = Val_Numeric then
               return (Kind    => Val_Integer,
                       Int_Val => Integer (Float'Truncation (V.Num_Val)));
            end if;
            raise SData_Core.Script_Error
              with "cannot convert string value to integer";
         when Val_String =>
            raise SData_Core.Script_Error
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
               Img : constant String := Float'Image (V.Num_Val);
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
               package Float_IO is new Ada.Text_IO.Float_IO (Float);
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
                  return Trim (Float'Image (V.Num_Val), Ada.Strings.Both);
            end;
         when others => return To_String (V);
      end case;
   end To_String_Formatted;

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
   function "=" (L, R : Value) return Boolean is
   begin
      if L.Kind /= R.Kind then
         -- Promotion logic for comparison
         if L.Kind = Val_Numeric and R.Kind = Val_Integer then
            return L.Num_Val = Float (R.Int_Val);
         elsif L.Kind = Val_Integer and R.Kind = Val_Numeric then
            return Float (L.Int_Val) = R.Num_Val;
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
      -- Missing is always smallest
      if L.Kind = Val_Missing then
         return R.Kind /= Val_Missing;
      elsif R.Kind = Val_Missing then
         return False;
      end if;

      if L.Kind = Val_Numeric or L.Kind = Val_Integer then
         declare
            FL : constant Float :=
               (if L.Kind = Val_Numeric then L.Num_Val else Float (L.Int_Val));
         begin
            if R.Kind = Val_Numeric or R.Kind = Val_Integer then
               declare
                  --  FR is only safe to compute once R is known to be
                  --  Numeric or Integer; computing it earlier would fail
                  --  the discriminant check for R = String.
                  FR : constant Float :=
                     (if R.Kind = Val_Numeric then R.Num_Val
                                              else Float (R.Int_Val));
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
   --  Float'Last * 2.0 must be computed at runtime to avoid the
   --  static-expression Constraint_Error GNAT raises at compile time.
   --  Big cannot be constant for the same reason; suppress the spurious warning.
   --  Validity checks are disabled project-wide via -gnatVn (see sdata_core.gpr)
   --  because this package legitimately stores IEEE 754 infinity in float vars.
   declare
      pragma Warnings (Off, "could be declared constant");
      Big : Float := Float'Last;
      pragma Warnings (On, "could be declared constant");
   begin
      Pos_Inf :=  Big * 2.0;
      Neg_Inf := -(Big * 2.0);
   end;
end SData_Core.Values;