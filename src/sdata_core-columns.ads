--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Columns holds the shared data vocabulary for the Table
--  subsystem: the column value type, the typed column record, and the
--  name-keyed column map.  It is foundational and independent -- it withs
--  nothing inside the Table cluster, so Backing_Store / Sorting / Grouping can
--  all build on it without a dependency cycle.

with Ada.Strings.Hash;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with SData_Core.Values; use SData_Core.Values;

package SData_Core.Columns is

   --  Kinds of data allowed in a column.
   type Column_Type is (Col_Numeric, Col_Integer, Col_String);

   --  Vector of values for a single column.
   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value);

   --  The internal representation of a column.
   type Column is record
      Name : String (1 .. Max_Name_Len); -- Padded name
      Typ  : Column_Type;      -- Enforced type
      Data : Value_Vectors.Vector; -- List of values (one per row)
      --  Output columns only: True when Typ was a placeholder inferred from a
      --  leading missing value of a derived column; cleared (and Typ set) on
      --  the first non-missing write.  See Add_Output_Column / Set_Output_Value*.
      Type_Is_Placeholder : Boolean := False;
   end record;

   --  Map from column name (String) to Column record.
   package Column_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String,
      Element_Type => Column,
      Hash => Ada.Strings.Hash,
      Equivalent_Keys => "=");

end SData_Core.Columns;
