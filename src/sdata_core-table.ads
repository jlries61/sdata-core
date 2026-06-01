--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Table implements the Data Table Manager, providing an in-memory 
--  2D table structure for storing and manipulating records and columns.
--  Columns are typed (Numeric or String) and the table maintains consistency 
--  between rows.

with Ada.Finalization;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with SData_Core.Values; use SData_Core.Values;

with Ada_Sqlite3;

package SData_Core.Table is

   --  Resets the table state (removes all columns and rows).
   procedure Clear;

   --  Kinds of data allowed in a column.
   type Column_Type is (Col_Numeric, Col_Integer, Col_String);

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

   --  Appends a new empty row to the table (all values initialized to Val_Missing).
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

   -- Sorts the table based on the given criteria.
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
   procedure Add_Output_Column (Name : String; Col_Type : Column_Type);
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
   --  Vector of values for a single column.
   package Value_Vectors is new Ada.Containers.Vectors (Index_Type => Positive, Element_Type => Value);

   --  The internal representation of a column.
   type Column is record
      Name : String (1 .. Max_Name_Len); -- Padded name
      Typ  : Column_Type;      -- Enforced type
      Data : Value_Vectors.Vector; -- List of values (one per row)
   end record;
   
   --  Map from column name (String) to Column record.
   package Column_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String,
      Element_Type => Column,
      Hash => Ada.Strings.Hash,
      Equivalent_Keys => "=");

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
   Output_Column_Order : Name_Vectors.Vector;
   Output_Table_Row_Count : Natural := 0;
   Record_Explicitly_Written : Boolean := False;

   --  Maintains the insertion order of column names for range expansion.
   Column_Order : Name_Vectors.Vector;
   
   --  Explicit row count (to handle cases where columns haven't been added yet).
   Table_Row_Count : Natural := 0;

   --  Current record pointer for the interpreter.
   Current_Record : Natural := 0;
   
   -- Logical record number (respecting filters)
   Logical_Record : Natural := 0;

   -- Segment tracking for disk spillover
   Current_Segment_Start : Positive := 1;
   Output_Segment_Start  : Positive := 1;

   --  Segment-level prefetch cache for disk-backed rows.
   --  Holds all rows for one spilled segment; populated on first access to
   --  any row in that segment and reused until a different segment is needed.
   --  Per-column data is stored in Value_Vectors.Vector, indexed by
   --  (row - Seg_Start + 1).
   package Seg_Data_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Value_Vectors.Vector,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=",
      "="             => Value_Vectors."=");
   Seg_Cache : Seg_Data_Maps.Map;
   Seg_Start : Natural := 0;  --  0 = empty; first logical row of cached segment
   Seg_End   : Natural := 0;  --  last logical row of cached segment

   --  SQLite Backing Store
   --  Derived from Limited_Controlled so that Finalize runs automatically at
   --  program exit (including on unhandled exception), deleting the temp file.
   type Database_Access is access all Ada_Sqlite3.Database;
   type Backing_Store is new Ada.Finalization.Limited_Controlled with record
      DB          : Database_Access := null;
      Is_Active   : Boolean := False;
      Temp_Path   : Unbounded_String;
      Row_Limit   : Natural := 0; -- -m value
   end record;
   overriding procedure Finalize (S : in out Backing_Store);

   Store : Backing_Store;

   --  Storage Management Procedures
   procedure Initialize_Backing_Store;
   procedure Spill_To_Disk;
   function Fetch_From_Disk (Row : Positive; Col_Name : String) return Value;

end SData_Core.Table;