--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Values defines the core data types used within the SData interpreter.
--  It provides a variant record type 'Value' that can represent numeric (Float),
--  integer (Integer), string, or missing values, along with utility functions.

with Ada.Strings.Unbounded;

package SData_Core.Values is
   pragma Elaborate_Body;

   --  Kind of data stored in a Value record.
   type Value_Kind is (Val_Numeric, Val_Integer, Val_String, Val_Missing);

   --  The main data container for the interpreter.
   type Value (Kind : Value_Kind := Val_Missing) is record
      case Kind is
         when Val_Numeric =>
            Num_Val : Float;
         when Val_Integer =>
            Int_Val : Integer;
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
   function Is_Inf (F : Float) return Boolean;

   --  IEEE 754 infinity sentinels produced at package elaboration.
   --  Use these wherever +Inf or -Inf must be produced at runtime.
   Pos_Inf : Float;
   Neg_Inf : Float;

   --  Like To_String, but respects global precision settings for Floats.
   function To_String_Formatted (V : Value) return String;

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
   function "=" (L, R : Value) return Boolean;
   function "<" (L, R : Value) return Boolean;

end SData_Core.Values;