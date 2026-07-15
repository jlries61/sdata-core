--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Values defines the core data types used within the SData interpreter.
--  It provides a variant record type 'Value' that can represent numeric (Float),
--  integer (Integer), string, or missing values, along with utility functions.

with Ada.Strings.Unbounded;

package SData_Core.Values is
   pragma Elaborate_Body;

   --  The interpreter's numeric value types, defined once here and used
   --  everywhere (see doc/specs/2026-07-13-64bit-numeric-types-design.md).
   --  Introduced first as subtypes of the predefined types so the migration
   --  is transparent; strengthened to distinct 64-bit types in a later step
   --  (Real -> 'digits 15', Int -> 'range -2**63 .. 2**63-1').  Changing
   --  precision is then a change to these two lines.
   type Real is digits 15;                   --  portable IEEE 754 double
   subtype Int  is Integer;

   --  Kind of data stored in a Value record.
   type Value_Kind is (Val_Numeric, Val_Integer, Val_String, Val_Missing);

   --  The main data container for the interpreter.
   type Value (Kind : Value_Kind := Val_Missing) is record
      case Kind is
         when Val_Numeric =>
            Num_Val : Real;
         when Val_Integer =>
            Int_Val : Int;
         when Val_String =>
            Str_Val : Ada.Strings.Unbounded.Unbounded_String;
         when Val_Missing =>
            null;
      end case;
   end record;

   --  Converts a Value to its string representation.
   --  Integers are formatted without decimals or scientific notation.
   function To_String (V : Value) return String;

   --  Returns True for IEEE 754 positive or negative infinity.
   --  Returns False for finite values, Missing, and NaN.
   function Is_Inf (F : Real) return Boolean;

   --  IEEE 754 infinity sentinels produced at package elaboration.
   --  Use these wherever +Inf or -Inf must be produced at runtime.
   Pos_Inf : Real;
   Neg_Inf : Real;

   --  Like To_String, but respects global precision settings for Floats.
   function To_String_Formatted (V : Value) return String;

   --  Round-trip float rendering used by the CSV/ODF/OOXML writers for the
   --  default (no /DECIMALS) numeric output: the shortest fixed-notation
   --  decimal that reads back to exactly X, trailing zeros trimmed, with an
   --  exponential fallback for extreme magnitudes.  Reproduces the stored
   --  double-precision Real exactly (up to 17 significant digits; Real'Image
   --  is comparatively lossy for round-tripping).
   function Image_Round_Trip (X : Real) return String;

   --  Fixed-decimals rendering for SAVE /DECIMALS=N on CSV: round X to
   --  Decimals places, then trim trailing zeros and any bare '.'.
   --  Decimals = 0 rounds to the nearest integer.
   function Image_Fixed_Decimals (X : Real; Decimals : Natural) return String;

   --  Convert V to the requested numeric-family kind.
   --  Val_Numeric <-> Val_Integer convert (Numeric -> Integer truncates
   --  toward zero, matching LET coercion); Val_Missing passes through; a
   --  Value already of kind Target is returned unchanged.  Raises
   --  Conversion_Error if a string is involved on either side (string value
   --  with a numeric Target, or string Target with a numeric value), i.e.
   --  the numeric/character boundary, which this routine does not cross.
   function Convert_Value (V : Value; Target : Value_Kind) return Value;

   --  Raised by Convert_Value for an unsupported string <-> numeric crossing.
   Conversion_Error : exception;

   --  Determines the boolean truth of a value.
   function Is_True (V : Value) return Boolean;

   --  Comparison functions
   overriding function "=" (L, R : Value) return Boolean;
   function "<" (L, R : Value) return Boolean;

end SData_Core.Values;