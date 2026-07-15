--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Containers.Vectors;
with SData_Core.Values;  use SData_Core.Values;

package SData_Core.CSV is

   type Field_Pair is record S, E : Natural; end record;

   package Field_Vectors is new Ada.Containers.Vectors (Positive, Field_Pair);

   function Try_Fast_Float   (S         : String;
                               Result    : out Real) return Boolean;

   function Is_Numeric_Field (F : String) return Boolean;

   function At_Delimiter     (Line      : String;
                               Pos       : Positive;
                               Delimiter : String) return Boolean;

   function CSV_Field_End    (Line      : String;
                               From      : Positive;
                               Delimiter : String) return Natural;

   function CSV_Unquote      (Raw : String) return String;

   procedure Split_Indices   (Line      : String;
                               Delimiter : String;
                               Fields    : in out Field_Vectors.Vector);

end SData_Core.CSV;