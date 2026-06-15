--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Columns holds the shared data vocabulary for the Table
--  subsystem: the column value type, the typed column record, and the
--  name-keyed column map.  Built on SData_Core.Column_Names (the private
--  Column_Name type) and re-exporting its boundary operations so the Table
--  facade and the M3-M5 units convert without separately withing Column_Names.

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Column_Names;

package SData_Core.Columns is

   --  Re-export the private name type + its boundary ops (see Column_Names).
   subtype Column_Name is SData_Core.Column_Names.Column_Name;
   function To_Column_Name (S : String) return Column_Name
     renames SData_Core.Column_Names.To_Column_Name;
   function Image (N : Column_Name) return String
     renames SData_Core.Column_Names.Image;
   function "=" (L, R : Column_Name) return Boolean
     renames SData_Core.Column_Names."=";

   --  Strip the leading space Integer'Image prepends for non-negative values
   --  so diagnostic strings read "rows=123" rather than "rows= 123".  Shared
   --  by Backing_Store, Sorting, and the Table facade for structured error
   --  context.
   function Img (N : Integer) return String;

   --  Kinds of data allowed in a column.
   type Column_Type is (Col_Numeric, Col_Integer, Col_String);

   --  Vector of values for a single column.
   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value);

   --  Insertion-order list of column names (replaces the old Unbounded_String
   --  Column_Order / Output_Column_Order vectors).  Distinct from
   --  Table.Name_Vectors, which is a consumer-facing public type and stays.
   package Column_Name_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column_Name);

   --  The internal representation of a column.
   type Column is record
      Name : Column_Name;
      Typ  : Column_Type;
      Data : Value_Vectors.Vector;
      Type_Is_Placeholder : Boolean := False;
   end record;

   --  Map keyed by the canonical Column_Name.
   package Column_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => Column_Name,
      Element_Type    => Column,
      Hash            => SData_Core.Column_Names.Hash,
      Equivalent_Keys => SData_Core.Column_Names."=");

   --  Sorting support.  Relocated here (from Table) so SData_Core.Sorting can
   --  build on it without a with-cycle; Table re-exports unchanged (sec 4.4).
   --  Sort_Criteria.Name keeps its fixed-width String tail (the J1 public
   --  surface), explicitly out of the Column_Name conversion's scope.
   type Sort_Direction is (Ascending, Descending);
   type Sort_Criteria is record
      Name : String (1 .. Max_Name_Len);
      Len  : Natural;
      Dir  : Sort_Direction;
   end record;
   type Sort_Criteria_Array is array (Positive range <>) of Sort_Criteria;

end SData_Core.Columns;
