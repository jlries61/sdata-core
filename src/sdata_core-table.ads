--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Table implements the Data Table Manager, providing an in-memory
--  2D table structure for storing and manipulating records and columns.
--  Columns are typed (Numeric or String) and the table maintains consistency
--  between rows.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Table is

   --  Resets the table state (removes all columns and rows).
   procedure Clear;

   --  Kinds of data allowed in a column.  Relocated to SData_Core.Columns and
   --  re-exported here so the public API is byte-for-byte unchanged.  The
   --  subtype + literal renames are not enough on their own: the enumeration's
   --  predefined "=" now lives in Columns, so a caller doing `use
   --  SData_Core.Table` (without `use type`) would lose direct visibility of
   --  it.  Re-exporting "=" here restores the prior directly-visible operator
   --  set.  See ADR-0007 / spec sec 4.1.
   subtype Column_Type is SData_Core.Columns.Column_Type;
   function Col_Numeric return Column_Type renames SData_Core.Columns.Col_Numeric;
   function Col_Integer return Column_Type renames SData_Core.Columns.Col_Integer;
   function Col_String  return Column_Type renames SData_Core.Columns.Col_String;
   function "=" (Left, Right : Column_Type) return Boolean
     renames SData_Core.Columns."=";

   --  Defines a new column. If the table already has rows, they are padded with missing values.
   procedure Add_Column (Name : String; Col_Type : Column_Type);

   --  Checks if a column with the given name (case-insensitive) exists.
   function Has_Column (Name : String) return Boolean;

   --  Returns the declared Column_Type for the named column. Raises
   --  Constraint_Error if the column does not exist (caller should test
   --  Has_Column first when uncertainty is possible).
   function Get_Column_Type (Name : String) return Column_Type;

   --  Returns the number of columns in the table.
   function Column_Count return Natural;

   --  Returns the Ith column name in user-visible (insertion) order, 1-based.
   --  Used to iterate column names without heap-allocating a String_List.
   function Column_Name (I : Positive) return String;

   --  Returns the number of rows (records) in the table.
   function Row_Count return Natural;

   --  Appends a new empty row to the table (all values initialized to
   --  Val_Missing).
   --
   --  Spill / cost-class contract: when Config.Max_Table_Cells > 0, Add_Row
   --  transparently spills the current in-memory segment to the SQLite backing
   --  store once it fills -- i.e. when
   --  (rows-in-segment * Column_Count) >= Max_Table_Cells -- so at most
   --  Max_Table_Cells / Column_Count rows are resident at a time.  This makes
   --  the table larger-than-RAM at the price of a read-cost transition: a row
   --  in the live (unspilled) segment reads in O(1) by vector index, but a row
   --  in a spilled segment costs O(segment) on first access -- one SQL query
   --  materializes the whole segment into the prefetch cache (see
   --  Fetch_From_Disk) -- and O(1) thereafter while that segment stays cached.
   --  Sequential scans pay one fetch per segment; random access across segments
   --  thrashes the single-segment cache (Seg_Cache holds one segment, no LRU).
   --  Max_Table_Cells = 0 disables spilling: every row stays in memory, always
   --  O(1).  See Spill_Table_To_Disk for the all-or-nothing write contract.
   procedure Add_Row;

   --  Retrieves the value for a specific row and column.
   function Get_Value (Row : Positive; Column_Name : String) return Value;
   function Get_Value_Upper (Row : Positive; Upper_Name : String) return Value;

   --  Updates the value at a specific row and column.
   --  Raises Type_Mismatch_Error if the value kind doesn't match the column type.
   procedure Set_Value (Row : Positive; Column_Name : String; Val : Value);
   procedure Set_Value_Upper (Row : Positive; Upper_Name : String; Val : Value);

   --  Renames an existing column.
   procedure Rename_Column (Old_Name, New_Name : String);

   --  Removes a column from the table.
   procedure Drop_Column (Name : String);

   --  Removes a specific row from the table.
   procedure Drop_Row (Index : Positive);

   --  Sorting support
   type Sort_Direction is (Ascending, Descending);
   type Sort_Criteria is record
      Name : String (1 .. Max_Name_Len);
      Len  : Natural;
      Dir  : Sort_Direction;
   end record;
   type Sort_Criteria_Array is array (Positive range <>) of Sort_Criteria;

   --  Sorts the table based on the given criteria.
   procedure Sort (Criteria : Sort_Criteria_Array);

   --  Sets/Gets the pointer to the current record during data step iteration.
   procedure Set_Current_Record_Index (Index : Natural);
   function Get_Current_Record_Index return Natural;

   procedure Set_Logical_Record_Index (Index : Natural);
   function Get_Logical_Record_Index return Natural;

   --  Filtered view support (SELECT filter)
   type Index_Array is array (Positive range <>) of Positive;
   procedure Set_Index_Map (Map : Index_Array);
   procedure Clear_Index_Map;
   function Logical_To_Physical (Logical : Positive) return Positive;
   function Logical_Row_Count return Natural;
   function Is_Filtered return Boolean;

   --  Output Table Management
   procedure Initialize_Output_Table;
   --  From_Missing => True marks the column's type as a placeholder inferred
   --  from a leading missing value of a non-table (derived) column.  Such a
   --  placeholder is upgraded to the first non-missing value's kind on write
   --  (see Set_Output_Value*), so a missing-first-then-character derived column
   --  is not locked to Numeric.  A deliberately-typed column (From_Missing
   --  False) is never upgraded.
   procedure Add_Output_Column
     (Name : String; Col_Type : Column_Type; From_Missing : Boolean := False);

   --  Appends an empty row to the output table.  Carries the same spill /
   --  cost-class contract as Add_Row -- threshold Config.Max_Table_Cells,
   --  O(1) live-segment vs O(segment) disk-backed reads -- applied to the
   --  independent Output_* segment (Output_Segment_Start, Spill_Output_To_Disk).
   procedure Add_Output_Row;
   procedure Set_Output_Value (Row : Positive; Column_Name : String; Val : Value);
   procedure Set_Output_Value_Upper (Row : Positive; Upper_Name : String; Val : Value);
   procedure Commit_Output_Table;
   function Output_Row_Count return Natural;

   --  Position-indexed accessors using the pre-resolved cursor cache.
   --  Col_Pos is 1-based column index matching Column_Order / Output_Column_Order.
   --  O(1): no hash lookup, no Contains check.
   function Get_Value_By_Col (Row : Positive; Col_Pos : Positive) return Value;
   procedure Set_Output_Value_By_Col (Row : Positive; Col_Pos : Positive; Val : Value);

   procedure Set_Record_Explicitly_Written (State : Boolean);
   function Get_Record_Explicitly_Written return Boolean;

   --  Returns the backing-store temp file path, or "" if the store is not active.
   --  Used by the signal handler to clean up on SIGTERM/SIGINT.
   function Get_Backing_Store_Path return String;

   --  BY-group support.  The interpreter registers the active BY variable
   --  names here so that the evaluator can query group membership without
   --  depending on the interpreter package.
   procedure Clear_By_Vars;
   procedure Add_By_Var (Name : String);
   function By_Var_Count return Natural;
   function By_Var_Name (I : Positive) return String;
   function In_Same_Group (Idx1, Idx2 : Positive) return Boolean;

   --  Package to store lists of column names.
   package Name_Vectors is new Ada.Containers.Vectors (Index_Type => Positive, Element_Type => Unbounded_String);

   Type_Mismatch_Error : exception;

private
   --  Pre-resolved cursor cache for O(1) positional column access during the
   --  data step hot path.  Parallel to Column_Order / Output_Column_Order;
   --  rebuilt whenever the schema changes (Add_Column, Drop_Column, etc.).
   package Cursor_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Column_Maps.Cursor,
      "="          => Column_Maps."=");
   Column_Cursor_Cache : Cursor_Vectors.Vector;
   Output_Cursor_Cache : Cursor_Vectors.Vector;

   --  The global data table state.
   Data_Table : Column_Maps.Map;

   Output_Data_Table : Column_Maps.Map;
   Output_Column_Order : Columns.Column_Name_Vectors.Vector;
   Output_Table_Row_Count : Natural := 0;
   Record_Explicitly_Written : Boolean := False;

   --  Maintains the insertion order of column names for range expansion.
   Column_Order : Columns.Column_Name_Vectors.Vector;

   --  Explicit row count (to handle cases where columns haven't been added yet).
   Table_Row_Count : Natural := 0;

   --  Current record pointer for the interpreter.
   Current_Record : Natural := 0;

   --  Logical record number (respecting filters)
   Logical_Record : Natural := 0;

   --  Segment tracking for disk spillover
   Current_Segment_Start : Positive := 1;
   Output_Segment_Start  : Positive := 1;

   --  Single owned spill kernel.  Package-level singleton (not a stack object)
   --  so finalization timing is unchanged (spec risk table, row 4).
   Store : SData_Core.Backing_Store.Backing_Store;

end SData_Core.Table;