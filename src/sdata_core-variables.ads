--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Variables implements the Symbol Table for the interpreter.
--  It distinguishes between Temporary (memory only) and Permanent (table-linked) variables.

with SData_Core.Values; use SData_Core.Values;
with SData_Core.Table;  use SData_Core.Table;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNAT.Strings;

package SData_Core.Variables is

   --  Creates or updates a temporary variable. Fails if name matches a table column.
   procedure Set_Temporary (Name : String; Val : Value);

   --  Ensures a variable is permanent. Fails if the name is an existing
   --  genuine temporary variable (a held-permanent variable's Temp_Symbols
   --  carry-over shadow is not "temporary" for this purpose -- see Is_Held).
   procedure Set_Permanent (Name : String; Val : Value);

   --  Retrieves a value. Lookup order: 1. Permanent PDV, 2. Temporary symbols.
   function Get (Name : String) return Value;

   --  Returns True if the name exists in either the PDV or the temporary symbol table,
   --  regardless of whether its current value is missing.
   function Defined (Name : String) return Boolean;

   --  Removes a session variable.
   procedure Unset (Name : String);

   --  Removes every genuine temporary (SET) variable, skipping any name
   --  currently marked Held. A held permanent variable's Temp_Symbols entry
   --  is a carry-over mirror maintained by Reset_PDV_Non_Held / Set_Permanent
   --  (see Is_Held), not a genuine temporary -- Unset_All must not disturb an
   --  unrelated HOLD in effect. Called by UNSET /ALL.
   procedure Unset_All;

   --  Removes all temporary variables (called by NEW).
   procedure Clear_Temporary;

   --  PDV Management (PDV stands for Program Data Vector)
   procedure Initialize_PDV;
   --  Load all table columns for Row into the PDV.
   procedure Load_PDV_From_Table (Row : Positive);
   --  Load a single already-upper-cased column Col_Name for Row into the PDV.
   --  Used by the SELECT filter scan to load only the columns the filter references.
   procedure Load_PDV_One_Column (Row : Positive; Col_Name : String);
   procedure Reset_PDV_Non_Held;
   procedure Refresh_PDV_Names;

   --  Indexed PDV access — used by the evaluator hot path after pre-resolution.
   --  Returns the 1-based slot index for Name in the PDV vector, 0 if absent.
   function PDV_Resolve (Name : String) return Natural;
   --  Direct slot read (caller must ensure Idx in 1 .. PDV_Size).
   function Get_PDV_Value (Idx : Positive) return Value;

   package Symbol_Table_Pkg is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type   => Value,
      Hash           => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  Flushes the current PDV to the Output Table
   procedure Flush_PDV_To_Output;

   function Get_Type (Name : String) return Value_Kind;

   function Get_PDV_Names return GNAT.Strings.String_List_Access;

   function Get_Session_Names return GNAT.Strings.String_List_Access;

   --  Array Management
   --  Defines a virtual array (maps existing variables)
   procedure Define_Array (Name : String; Constituents : GNAT.Strings.String_List);
   procedure Define_Array (Name : String; Constituents : Name_Vectors.Vector); -- For internal use
   procedure Define_Array_Access (Name : String; Constituents : GNAT.Strings.String_List_Access);

   --  Removes a virtual array definition by name (no effect on constituent variables or real arrays)
   procedure Undefine_Virtual_Array (Name : String);

   --  Removes an array's registration (virtual or real) regardless of Kind,
   --  without touching its constituent/element columns -- the caller is
   --  responsible for deleting those first (e.g. Execute_DROP, per
   --  design.md's Deletion rules: "If virtual array mentioned in DROP, all
   --  constituent variables are deleted along with virtual array
   --  definition"; the same total-deletion behavior applies to real arrays,
   --  since "Individual array elements cannot be deleted" -- DROP only
   --  operates on whole arrays). No effect if Name is not a registered
   --  array. Distinct from Undefine_Virtual_Array, which is the lighter-
   --  weight ARRAY-statement primitive that intentionally leaves
   --  constituent data alone and only accepts virtual arrays.
   procedure Undefine_Array (Name : String);

   --  Prints all currently defined virtual arrays to console output
   procedure List_Virtual_Arrays;

   --  Creates or resizes a real array (generates numbered variables)
   procedure Dim_Array (Name : String; Start_Idx, End_Idx : Integer; Is_Temp : Boolean);

   --  Reads element Index of array Name. Raises SData_Core.Script_Error if
   --  Name is not a defined array, if Index falls outside the array's
   --  declared range, or (Virtual_Array only) if the resolved offset exceeds
   --  the registered constituent count.
   function Get_Array_Element (Name : String; Index : Integer) return Value;

   --  Writes element Index of array Name. Raises SData_Core.Script_Error
   --  under the same three conditions as Get_Array_Element.
   procedure Set_Array_Element (Name : String; Index : Integer; Val : Value);
   function Has_Array (Name : String) return Boolean;
   function Is_Temporary_Array (Name : String) return Boolean;

   --  Returns True iff writing element Index of array Name should go through
   --  Set_Temporary (SET) rather than Set_Permanent (LET) -- the per-element
   --  sibling of Is_Temporary_Array's array-wide query. For a Real_Array
   --  this is the array-wide Is_Temporary flag (uniform by construction --
   --  DIM .../TEMP applies to every element). For a Virtual_Array this is
   --  the *resolved constituent's own* storage class: True iff it is a
   --  genuine temporary (present in Temp_Symbols and not currently Held --
   --  the same "genuine temporary" test Set_Permanent's own ADR-0010 check
   --  uses, so a held-permanent variable's Temp_Symbols carry-over mirror
   --  does not misdispatch). A constituent that is neither a table column
   --  nor in Temp_Symbols (never yet assigned) returns False.
   --
   --  Raises SData_Core.Script_Error under the same three conditions as
   --  Get_Array_Element/Set_Array_Element: Name is not a defined array,
   --  Index falls outside the array's declared range, or (Virtual_Array
   --  only) the resolved offset exceeds the registered constituent count.
   function Array_Element_Is_Temporary (Name : String; Index : Integer) return Boolean;

   --  Returns the bounds of an array if it exists.
   procedure Get_Array_Bounds (Name : String; Start_Idx, End_Idx : out Integer);

   --  Returns the physical table column name for element Index of the named array.
   --  For Real_Array (DIM): "NAME(Index)".
   --  For Virtual_Array (ARRAY): the constituent variable name at that position.
   function Get_Array_Element_Column (Name : String; Index : Integer) return String;

   --  Scan the current table column names for the pattern base(n) where n is
   --  a positive integer.  For each unique base name found, register the group
   --  as a DIM array spanning the minimum and maximum subscript observed.
   --  Gaps in the numeric sequence are permitted.  Call after Execute_USE.
   procedure Register_Subscripted_Columns;

   --  Post-load reconciliation (issue #132): USE/reshape commands overwrite
   --  the entire in-memory table, but Array_Symbols is a separate namespace
   --  Table.Add_Column has no visibility into (Table sits below Variables in
   --  this crate's dependency graph) and cannot guard against loading a
   --  literal column whose name collides with an already-registered array --
   --  the shadow-state defect ADR-0010/ADR-0012 closed for LET/SET/DIM,
   --  reappearing on this fourth path. Undefines the stale registration
   --  (ADR-0025, extending ADR-0015's "DIM silently replaces an existing
   --  virtual array" precedent to virtual and real arrays alike) so the
   --  freshly-loaded column becomes the name's sole, unambiguous meaning;
   --  prints a notice so the removal isn't silent. Call before
   --  Register_Subscripted_Columns so that routine's own messaging reflects
   --  post-reconciliation state. Call after Open_Input (or the reshape
   --  epilogue's table-commit step) so "every column in the table" and
   --  "every column this operation just loaded" are the same set.
   procedure Resolve_Column_Array_Collisions;

   --  Expands an array base Name into the actual column/variable names
   --  backing it: for a Virtual_Array, its Constituents as registered by
   --  Define_Array; for a Real_Array, the generated "Name(I)" names for
   --  I in its Start_Index .. End_Index (via Get_Array_Element_Column).
   --  Returns an empty vector if Name is not a registered array -- callers
   --  distinguish "not an array" from "array with no elements" via
   --  Has_Array, which they must already check before relying on that
   --  distinction (a real array's Start_Index > End_Index cannot occur;
   --  Dim_Array rejects it).
   function Expand_Array_Names (Name : String) return Name_Vectors.Vector;

   --  Hold/Unhold Management
   procedure Set_Hold (Name : String; State : Boolean);
   function Is_Held (Name : String) return Boolean;

   --  Group Management
   procedure Set_Current_Group_Key (Key : String);
   function Get_Current_Group_Key return String;

private
   --  Defines an array, whether virtual or real
   type Array_Kind is (Virtual_Array, Real_Array);

   type Array_Definition_Type is record
      Kind        : Array_Kind;
      Is_Temporary : Boolean := False; -- For Real_Array: If defined with /TEMP
      Start_Index : Integer := 1;      -- For Real_Array: Custom or 1-based
      End_Index   : Integer := 0;      -- For Real_Array: Derived from dimension or custom
      Constituents : Name_Vectors.Vector; -- For Virtual_Array: names of members; For Real_Array: generated names
   end record;
   overriding function "=" (Left, Right : Array_Definition_Type)
     return Boolean; -- Declare equality operator

   --  Holds only temporary variables created with SET.
   Temp_Symbols : Symbol_Table_Pkg.Map;

   --  Holds array definitions (virtual or real).
   package Array_Table_Pkg is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Array_Definition_Type,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=",
      "="             => "=");
   Array_Symbols : Array_Table_Pkg.Map;

   --  Tracks held status.
   package Hold_Table_Pkg is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Boolean,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");
   Hold_Symbols : Hold_Table_Pkg.Map;

   Current_Group_ID : Unbounded_String := Null_Unbounded_String;

   --  Flat vector of PDV values; slot I corresponds to PDV_Names(I).
   --  Replaces the old Permanent_Symbols hash map for O(1) indexed access.
   package PDV_Value_Vecs is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Value);

   --  Name → 1-based slot index in PDV_Vec / PDV_Names.
   package PDV_Index_Pkg is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Positive,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   PDV_Vec   : PDV_Value_Vecs.Vector;   -- indexed by slot (1-based)
   PDV_Names : Name_Vectors.Vector;     -- slot → upper-case name
   PDV_Index : PDV_Index_Pkg.Map;       -- upper-case name → slot

end SData_Core.Variables;