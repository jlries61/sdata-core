--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Exceptions;
with SData_Core.Config;
with SData_Core.Sorting;

with Ada.Unchecked_Deallocation;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Table is

   use type Ada.Containers.Count_Type;

   --  Rebuilds Column_Cursor_Cache to match Column_Order after any schema change.
   --  Must be called after every Insert/Delete/Rename on Data_Table or after a
   --  deep-copy assignment, since those operations may invalidate existing cursors.
   procedure Rebuild_Column_Cache is
   begin
      Column_Cursor_Cache.Clear;
      for I in 1 .. Natural (Column_Order.Length) loop
         Column_Cursor_Cache.Append
           (Data_Table.Find (Column_Order.Element (I)));
      end loop;
   end Rebuild_Column_Cache;

   procedure Rebuild_Output_Cache is
   begin
      Output_Cursor_Cache.Clear;
      for I in 1 .. Natural (Output_Column_Order.Length) loop
         Output_Cursor_Cache.Append
           (Output_Data_Table.Find (Output_Column_Order.Element (I)));
      end loop;
   end Rebuild_Output_Cache;

   procedure Spill_To_Disk;
   procedure Spill_Output_To_Disk;

   --  Filtered View Mapping
   type Index_Array_Access is access Index_Array;
   Filter_Map    : Index_Array_Access := null;

   --  BY-group variable names (upper-cased); mirrored from the interpreter.
   Table_By_Vars : Columns.Column_Name_Vectors.Vector;

   -----------
   -- Clear --
   -----------
   procedure Clear is
   begin
      Store.Close;
      Data_Table.Clear;
      Column_Order.Clear;
      Table_Row_Count := 0;
      Current_Record := 0;
      Logical_Record := 0;
      Clear_Index_Map;
      Current_Segment_Start := 1;
      Rebuild_Column_Cache;
   end Clear;

   ----------------
   -- Add_Column --
   ----------------
   procedure Add_Column (Name : String; Col_Type : Column_Type) is
      Key : constant Columns.Column_Name := To_Column_Name (Name);
      New_Col : Column;
   begin
      if Data_Table.Contains (Key) then
         return;
      end if;

      New_Col.Name := Key;
      New_Col.Typ := Col_Type;

      --  Rule: New columns must match the existing table height.
      for I in 1 .. Table_Row_Count loop
         New_Col.Data.Append ((Kind => Val_Missing));
      end loop;

      Data_Table.Insert (Key, New_Col);
      Column_Order.Append (Key);

      --  Schema changed: invalidate segment cache and rebuild cursor cache.
      --  Insert may have triggered a rehash, invalidating all prior cursors.
      Store.Clear_Cache;
      Rebuild_Column_Cache;
   end Add_Column;

   ----------------
   -- Has_Column --
   ----------------
   function Has_Column (Name : String) return Boolean is
   begin
      return Data_Table.Contains (To_Column_Name (Name));
   end Has_Column;

   ---------------------
   -- Get_Column_Type --
   ---------------------
   function Get_Column_Type (Name : String) return Column_Type is
      Cursor : constant Column_Maps.Cursor :=
         Data_Table.Find (To_Column_Name (Name));
   begin
      if not Column_Maps.Has_Element (Cursor) then
         raise Constraint_Error with
           "Get_Column_Type: column not found: "
           & Ada.Characters.Handling.To_Upper (Name);
      end if;
      --  Read Typ through a Constant_Reference so the whole Column (and its
      --  entire Data vector) is not deep-copied just to read one enum field.
      --  Element () would copy every row, making per-record callers O(rows)
      --  and the overall data step O(rows^2).
      declare
         Ref : constant Column_Maps.Constant_Reference_Type :=
            Data_Table.Constant_Reference (Cursor);
      begin
         return Ref.Element.all.Typ;
      end;
   end Get_Column_Type;

   ------------------
   -- Column_Count --
   ------------------
   function Column_Count return Natural is
   begin
      return Natural (Data_Table.Length);
   end Column_Count;

   -----------------
   -- Column_Name --
   -----------------
   function Column_Name (I : Positive) return String is
   begin
      return Image (Column_Order.Element (I));
   end Column_Name;

   ---------------
   -- Row_Count --
   ---------------
   function Row_Count return Natural is
   begin
      return Table_Row_Count;
   end Row_Count;

   -------------
   -- Add_Row --
   -------------
   procedure Add_Row is
   begin
      --  Spill the current in-memory segment to disk once it reaches
      --  Max_Table_Cells (rows-in-segment * columns), then start a fresh
      --  segment.  This is the O(1)->O(segment) read-cost transition documented
      --  on Add_Row in table.ads; Spill_Table_To_Disk holds the write contract.
      if SData_Core.Config.Max_Table_Cells > 0 and then
         (Table_Row_Count - Current_Segment_Start + 1)
            * Natural (Data_Table.Length) >= SData_Core.Config.Max_Table_Cells
      then
         Spill_To_Disk;
         Current_Segment_Start := Table_Row_Count + 1;
      end if;

      Table_Row_Count := Table_Row_Count + 1;
      for Pos in Data_Table.Iterate loop
         Data_Table.Reference (Pos).Element.all.Data.Append ((Kind => Val_Missing));
      end loop;
   end Add_Row;

   ---------------
   -- Get_Value --
   ---------------
   function Get_Value (Row : Positive; Column_Name : String) return Value is
   begin
      return Get_Value_Upper (Row, Ada.Characters.Handling.To_Upper (Column_Name));
   end Get_Value;

   --  The "_Upper" suffix is historical: To_Column_Name canonicalizes the key
   --  internally now, so callers need not pre-upper-case Upper_Name.  Kept for
   --  signature compatibility (rename is low value, out of M4 scope).
   function Get_Value_Upper (Row : Positive; Upper_Name : String) return Value is
      Cur : constant Column_Maps.Cursor :=
         Data_Table.Find (To_Column_Name (Upper_Name));
   begin
      if not Column_Maps.Has_Element (Cur) then
         return (Kind => Val_Missing);
      end if;
      declare
         Ref : constant Column_Maps.Constant_Reference_Type :=
            Data_Table.Constant_Reference (Cur);
         Len : constant Natural := Natural (Ref.Element.all.Data.Length);
      begin
         if Row >= Current_Segment_Start and then Row < Current_Segment_Start + Len then
            return Ref.Element.all.Data.Element (Row - Current_Segment_Start + 1);
         elsif Store.Is_Active then
            return Store.Fetch (Row, Upper_Name, Data_Table, Table_Row_Count);
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Get_Value_Upper;

   procedure Set_Value (Row : Positive; Column_Name : String; Val : Value) is
   begin
      Set_Value_Upper (Row, Ada.Characters.Handling.To_Upper (Column_Name), Val);
   end Set_Value;

   --  Coerce Val to the type required by Col_Typ, or return Val unchanged if
   --  Val is already the right type or is missing.  Raises Type_Mismatch_Error
   --  if the value kind is incompatible with the column type.
   function Coerce_Value (Val : Value; Col_Typ : Column_Type; Col_Name : String) return Value is
   begin
      if Val.Kind = Val_Missing then
         return Val;
      end if;
      if Col_Typ = Col_Numeric and then Val.Kind /= Val_Numeric then
         if Val.Kind = Val_Integer then
            return Convert_Value (Val, Val_Numeric);
         end if;
         raise Type_Mismatch_Error with "Expected Numeric for column " & Col_Name;
      elsif Col_Typ = Col_Integer and then Val.Kind /= Val_Integer then
         if Val.Kind = Val_Numeric then
            return Convert_Value (Val, Val_Integer);
         end if;
         raise Type_Mismatch_Error with "Expected Integer for column " & Col_Name;
      elsif Col_Typ = Col_String and then Val.Kind /= Val_String then
         raise Type_Mismatch_Error with "Expected String for column " & Col_Name;
      end if;

      --  Enforce global string length limit (--clen) if set.
      if Val.Kind = Val_String and then SData_Core.Config.Max_String_Len > 0 then
         declare
            S : constant String := To_String (Val.Str_Val);
         begin
            if S'Length > SData_Core.Config.Max_String_Len then
               declare
                  Res : Value (Val_String);
               begin
                  Res.Str_Val := To_Unbounded_String (S (S'First .. S'First + SData_Core.Config.Max_String_Len - 1));
                  return Res;
               end;
            end if;
         end;
      end if;

      return Val;
   end Coerce_Value;

   procedure Set_Value_Upper (Row : Positive; Upper_Name : String; Val : Value) is
      Cur : constant Column_Maps.Cursor :=
         Data_Table.Find (To_Column_Name (Upper_Name));
   begin
      if not Column_Maps.Has_Element (Cur) then
         return;
      end if;
      declare
         Ref : constant Column_Maps.Reference_Type := Data_Table.Reference (Cur);
         Col : Column renames Ref.Element.all;
      begin
         if Row > Table_Row_Count then
            for I in Positive (Col.Data.Length) + 1 .. Row loop
               Col.Data.Append ((Kind => Val_Missing));
            end loop;
         end if;
         Col.Data.Replace_Element (Row - Current_Segment_Start + 1, Coerce_Value (Val, Col.Typ, Upper_Name));
      end;
   end Set_Value_Upper;

   -------------------
   -- Rename_Column --
   -------------------
   procedure Rename_Column (Old_Name, New_Name : String) is
      Old_Key : constant Columns.Column_Name := To_Column_Name (Old_Name);
      New_Key : constant Columns.Column_Name := To_Column_Name (New_Name);
      Old_Pos : constant Column_Maps.Cursor := Data_Table.Find (Old_Key);
   begin
      if Column_Maps.Has_Element (Old_Pos)
         and then not Data_Table.Contains (New_Key)
      then
         declare
            Old_Typ  : Column_Type;
            Old_Plc  : Boolean;
            New_Pos  : Column_Maps.Cursor;
            Inserted : Boolean;
         begin
            --  Snapshot the old column's metadata (cheap; no Data copy).
            declare
               Old_CR : constant Column_Maps.Constant_Reference_Type :=
                 Data_Table.Constant_Reference (Old_Pos);
            begin
               Old_Typ := Old_CR.Typ;
               Old_Plc := Old_CR.Type_Is_Placeholder;
            end;

            --  Insert a shell column with empty Data under the new key, then
            --  MOVE the value vector across rather than copying it.  The prior
            --  code copied the whole Data vector twice (once on Element, again
            --  on Insert) — O(rows) per rename.  Re-find the old key after the
            --  Insert so the move is robust against any rehash.
            Data_Table.Insert
              (New_Key,
               Column'(Name                => New_Key,
                       Typ                 => Old_Typ,
                       Data                => Value_Vectors.Empty_Vector,
                       Type_Is_Placeholder => Old_Plc),
               New_Pos, Inserted);
            declare
               Old_Ref : constant Column_Maps.Reference_Type :=
                 Data_Table.Reference (Data_Table.Find (Old_Key));
               New_Ref : constant Column_Maps.Reference_Type :=
                 Data_Table.Reference (New_Pos);
            begin
               Value_Vectors.Move
                 (Target => New_Ref.Data, Source => Old_Ref.Data);
            end;
            Data_Table.Delete (Old_Key);

            --  Data_Table is an unordered hash map, so Column_Order is the
            --  sole record of user-visible column sequence.  Patch the name
            --  in place rather than delete/re-append to preserve position.
            for I in 1 .. Natural (Column_Order.Length) loop
               if Column_Order.Element (I) = Old_Key then
                  Column_Order.Replace_Element (I, New_Key);
                  exit;
               end if;
            end loop;
            --  Insert may have triggered a rehash; rebuild cursor cache.
            Rebuild_Column_Cache;
         end;
      end if;
   end Rename_Column;

   -----------------
   -- Drop_Column --
   -----------------
   procedure Drop_Column (Name : String) is
      Key : constant Columns.Column_Name := To_Column_Name (Name);
      Pos : Column_Maps.Cursor := Data_Table.Find (Key);
   begin
      if Column_Maps.Has_Element (Pos) then
         Data_Table.Delete (Pos);
         for I in 1 .. Natural (Column_Order.Length) loop
            if Column_Order.Element (I) = Key then
               Column_Order.Delete (I);
               exit;
            end if;
         end loop;
         Rebuild_Column_Cache;
      end if;
   end Drop_Column;

   --------------
   -- Drop_Row --
   --------------
   procedure Drop_Row (Index : Positive) is
      Position : Column_Maps.Cursor := Data_Table.First;
   begin
      if Index > Table_Row_Count then return; end if;
      Table_Row_Count := Table_Row_Count - 1;
      while Column_Maps.Has_Element (Position) loop
         declare
            --  Mutate the column's Vector in place via a Reference view.
            --  Avoids the prior Element-copy + Replace_Element round-trip
            --  (each of which copied the full Value_Vectors.Vector).
            Data_Ref : Value_Vectors.Vector renames
               Data_Table.Reference (Position).Element.all.Data;
         begin
            if Index <= Positive (Data_Ref.Length) then
               Data_Ref.Delete (Index);
            end if;
         end;
         Column_Maps.Next (Position);
      end loop;
   end Drop_Row;

   ------------------------------
   -- Set_Current_Record_Index --
   ------------------------------
   procedure Set_Current_Record_Index (Index : Natural) is
   begin
      Current_Record := Index;
   end Set_Current_Record_Index;

   ----------
   -- Sort --
   ----------
   --  Thin delegator: the spilled SQL ORDER BY path and the in-memory stable
   --  merge-sort live in SData_Core.Sorting (U1 M4), operating on the column
   --  map + insertion order + criteria + Store.  Criteria is the re-exported
   --  Columns.Sort_Criteria_Array subtype, so it passes through directly.
   procedure Sort (Criteria : Sort_Criteria_Array) is
   begin
      Sorting.Sort (Data_Table, Column_Order, Criteria,
                    Table_Row_Count, Current_Segment_Start, Store);
   end Sort;

   ------------------------------
   -- Get_Current_Record_Index --
   ------------------------------
   function Get_Current_Record_Index return Natural is
   begin
      return Current_Record;
   end Get_Current_Record_Index;

   procedure Set_Logical_Record_Index (Index : Natural) is
   begin
      Logical_Record := Index;
   end Set_Logical_Record_Index;

   function Get_Logical_Record_Index return Natural is
   begin
      return Logical_Record;
   end Get_Logical_Record_Index;

   -------------------
   -- Set_Index_Map --
   -------------------
   procedure Set_Index_Map (Map : Index_Array) is
   begin
      Clear_Index_Map;
      Filter_Map := new Index_Array'(Map);
   end Set_Index_Map;

   ---------------------
   -- Clear_Index_Map --
   ---------------------
   procedure Clear_Index_Map is
      procedure Free is new Ada.Unchecked_Deallocation (Index_Array, Index_Array_Access);
   begin
      if Filter_Map /= null then
         Free (Filter_Map);
      end if;
   end Clear_Index_Map;

   -------------------
   -- Clear_By_Vars --
   -------------------
   procedure Clear_By_Vars is
   begin
      Table_By_Vars.Clear;
   end Clear_By_Vars;

   -----------------
   -- Add_By_Var  --
   -----------------
   procedure Add_By_Var (Name : String) is
   begin
      Table_By_Vars.Append (To_Column_Name (Name));
   end Add_By_Var;

   function By_Var_Count return Natural is
   begin
      return Natural (Table_By_Vars.Length);
   end By_Var_Count;

   function By_Var_Name (I : Positive) return String is
   begin
      return Image (Table_By_Vars.Element (I));
   end By_Var_Name;

   -------------------
   -- In_Same_Group --
   -------------------
   function In_Same_Group (Idx1, Idx2 : Positive) return Boolean is
   begin
      if Table_By_Vars.Is_Empty then return True; end if;
      if Idx1 = Idx2 then return True; end if;
      if Idx1 > Table_Row_Count or else Idx2 > Table_Row_Count then return False; end if;
      for V of Table_By_Vars loop
         declare
            Name : constant String := Image (V);
            Val1 : constant Value  := Get_Value_Upper (Idx1, Name);
            Val2 : constant Value  := Get_Value_Upper (Idx2, Name);
         begin
            if not (Val1 = Val2) then return False; end if;
         end;
      end loop;
      return True;
   end In_Same_Group;

   ----------------------------
   -- Get_Backing_Store_Path --
   ----------------------------
   function Get_Backing_Store_Path return String is
   begin
      return Store.Path;
   end Get_Backing_Store_Path;

   -------------------------
   -- Logical_To_Physical --
   -------------------------
   function Logical_To_Physical (Logical : Positive) return Positive is
   begin
      if Filter_Map = null then
         return Logical;
      elsif Logical <= Filter_Map'Length then
         return Filter_Map (Logical);
      else
         return Logical; -- Fallback
      end if;
   end Logical_To_Physical;

   ------------------------
   -- Logical_Row_Count --
   ------------------------
   function Logical_Row_Count return Natural is
   begin
      if Filter_Map = null then
         return Table_Row_Count;
      else
         return Filter_Map'Length;
      end if;
   end Logical_Row_Count;

   -----------------
   -- Is_Filtered --
   -----------------
   function Is_Filtered return Boolean is
   begin
      return Filter_Map /= null;
   end Is_Filtered;

   -----------------------------
   -- Output Table Management --
   -----------------------------

   procedure Initialize_Output_Table is
   begin
      Output_Data_Table.Clear;
      Output_Column_Order.Clear;
      Output_Table_Row_Count := 0;
      if Store.Is_Active then
         Store.Execute ("DROP TABLE IF EXISTS output_data");
      end if;
      Rebuild_Output_Cache;
   end Initialize_Output_Table;

   procedure Add_Output_Column
     (Name : String; Col_Type : Column_Type; From_Missing : Boolean := False) is
      Key : constant Columns.Column_Name := To_Column_Name (Name);
      New_Col : Column;
   begin
      if Output_Data_Table.Contains (Key) then return; end if;
      New_Col.Name := Key;
      New_Col.Typ := Col_Type;
      New_Col.Type_Is_Placeholder := From_Missing;

      for I in 1 .. Output_Table_Row_Count loop
         New_Col.Data.Append ((Kind => Val_Missing));
      end loop;

      Output_Data_Table.Insert (Key, New_Col);
      Output_Column_Order.Append (Key);
      --  Insert may have triggered a rehash; rebuild output cursor cache.
      Rebuild_Output_Cache;
   end Add_Output_Column;

   procedure Add_Output_Row is
   begin
      --  Same segment-spill trigger as Add_Row (see table.ads for the
      --  O(1)->O(segment) read-cost contract), against the Output_* segment.
      if SData_Core.Config.Max_Table_Cells > 0 and then
         (Output_Table_Row_Count - Output_Segment_Start + 1)
            * Natural (Output_Data_Table.Length) >= SData_Core.Config.Max_Table_Cells
      then
         Spill_Output_To_Disk;
         Output_Segment_Start := Output_Table_Row_Count + 1;
      end if;

      Output_Table_Row_Count := Output_Table_Row_Count + 1;
      for Pos in Output_Data_Table.Iterate loop
         Output_Data_Table.Reference (Pos).Element.all.Data.Append ((Kind => Val_Missing));
      end loop;
   end Add_Output_Row;

   --  Upgrade a placeholder output-column type (inferred from a leading missing
   --  value of a derived column) to the first non-missing value's kind, then
   --  clear the placeholder flag.  No-op for non-placeholder columns or missing
   --  values, so a deliberately-typed column is never downgraded (issue #24).
   procedure Upgrade_Placeholder_Type (Col : in out Column; Val : Value) is
   begin
      if not Col.Type_Is_Placeholder or else Val.Kind = Val_Missing then
         return;
      end if;
      case Val.Kind is
         when Val_Numeric => Col.Typ := Col_Numeric;
         when Val_Integer => Col.Typ := Col_Integer;
         when Val_String  => Col.Typ := Col_String;
         when Val_Missing => null;  --  unreachable (guarded above)
      end case;
      Col.Type_Is_Placeholder := False;
   end Upgrade_Placeholder_Type;

   procedure Set_Output_Value_Upper (Row : Positive; Upper_Name : String; Val : Value) is
      Cur : constant Column_Maps.Cursor :=
         Output_Data_Table.Find (To_Column_Name (Upper_Name));
   begin
      if not Column_Maps.Has_Element (Cur) then
         return;
      end if;
      declare
         Ref : constant Column_Maps.Reference_Type :=
            Output_Data_Table.Reference (Cur);
         Col : Column renames Ref.Element.all;
      begin
         Upgrade_Placeholder_Type (Col, Val);
         Col.Data.Replace_Element (Row - Output_Segment_Start + 1, Coerce_Value (Val, Col.Typ, Upper_Name));
      end;
   end Set_Output_Value_Upper;

   procedure Set_Output_Value (Row : Positive; Column_Name : String; Val : Value) is
   begin
      Set_Output_Value_Upper (Row, Ada.Characters.Handling.To_Upper (Column_Name), Val);
   end Set_Output_Value;

   procedure Commit_Output_Table is
      Output_Spilled : constant Boolean := Output_Segment_Start > 1;
   begin
      Store.Clear_Cache;
      if Output_Table_Row_Count = 0 and then Output_Data_Table.Is_Empty
        and then not Data_Table.Is_Empty
      then
         --  Clear each column's data in place through a Reference view; the
         --  prior Element + Replace_Element copied the whole Column out and
         --  back just to empty its Data vector.
         for Pos in Data_Table.Iterate loop
            Data_Table.Reference (Pos).Data.Clear;
         end loop;
         Table_Row_Count := 0;
         if Store.Is_Active then
            Store.Execute ("DROP TABLE IF EXISTS data");
            Store.Execute ("DROP TABLE IF EXISTS output_data");
         end if;
      else
         Data_Table := Output_Data_Table;
         Column_Order := Output_Column_Order;
         Table_Row_Count := Output_Table_Row_Count;
         --  Deep copy creates a new map; all prior Column_Cursor_Cache cursors are
         --  invalid.  Rebuild immediately before any caller can use Get_Value_By_Col.
         Rebuild_Column_Cache;

         if Store.Is_Active then
            Store.Execute ("DROP TABLE IF EXISTS data");
            if Output_Spilled then
               Spill_Output_To_Disk;
               Store.Execute ("ALTER TABLE output_data RENAME TO data");
            end if;
         end if;
      end if;
      Initialize_Output_Table;
      Current_Segment_Start := Output_Segment_Start;
      Output_Segment_Start := 1;
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not commit data step output to disk (disk full?)"
            & " [output_rows=" & Img (Output_Table_Row_Count)
            & ", spilled=" & (if Output_Spilled then "yes" else "no") & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Commit_Output_Table;

   function Output_Row_Count return Natural is
   begin
      return Output_Table_Row_Count;
   end Output_Row_Count;

   -----------------------
   -- Get_Value_By_Col --
   -----------------------
   function Get_Value_By_Col (Row : Positive; Col_Pos : Positive) return Value is
      --  The cursor cache must be current: a schema mutation that changed
      --  Data_Table without calling Rebuild_Column_Cache would leave stale or
      --  dangling cursors here.  Convert that by-convention invariant into a
      --  checked one (no-op unless assertions are enabled).  See Kleppmann K3.
      pragma Assert
        (Natural (Column_Cursor_Cache.Length) = Column_Count,
         "Column_Cursor_Cache stale (length"
         & Natural'Image (Natural (Column_Cursor_Cache.Length))
         & " /= Column_Count" & Natural'Image (Column_Count)
         & "); a schema mutation skipped Rebuild_Column_Cache");
      Cur : constant Column_Maps.Cursor := Column_Cursor_Cache.Element (Col_Pos);
   begin
      if not Column_Maps.Has_Element (Cur) then
         return (Kind => Val_Missing);
      end if;
      declare
         Ref : constant Column_Maps.Constant_Reference_Type :=
            Data_Table.Constant_Reference (Cur);
         Len : constant Natural := Natural (Ref.Element.all.Data.Length);
      begin
         if Row >= Current_Segment_Start and then Row < Current_Segment_Start + Len then
            return Ref.Element.all.Data.Element (Row - Current_Segment_Start + 1);
         elsif Store.Is_Active then
            return Store.Fetch
               (Row, Image (Column_Maps.Key (Cur)), Data_Table, Table_Row_Count);
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Get_Value_By_Col;

   ------------------------------
   -- Set_Output_Value_By_Col --
   ------------------------------
   procedure Set_Output_Value_By_Col (Row : Positive; Col_Pos : Positive; Val : Value) is
      --  Output analogue of the Get_Value_By_Col cache-currency check: a new
      --  Output_* mutator that forgets Rebuild_Output_Cache would corrupt
      --  silently.  See Kleppmann K3.
      pragma Assert
        (Natural (Output_Cursor_Cache.Length)
           = Natural (Output_Data_Table.Length),
         "Output_Cursor_Cache stale (length"
         & Natural'Image (Natural (Output_Cursor_Cache.Length))
         & " /= Output_Data_Table length"
         & Natural'Image (Natural (Output_Data_Table.Length))
         & "); a schema mutation skipped Rebuild_Output_Cache");
      Cur : constant Column_Maps.Cursor := Output_Cursor_Cache.Element (Col_Pos);
   begin
      if not Column_Maps.Has_Element (Cur) then
         return;
      end if;
      declare
         Ref : constant Column_Maps.Reference_Type :=
            Output_Data_Table.Reference (Cur);
         Col : Column renames Ref.Element.all;
      begin
         Upgrade_Placeholder_Type (Col, Val);
         Col.Data.Replace_Element
           (Row - Output_Segment_Start + 1,
            Coerce_Value (Val, Col.Typ, Image (Column_Maps.Key (Cur))));
      end;
   end Set_Output_Value_By_Col;

   procedure Set_Record_Explicitly_Written (State : Boolean) is
   begin
      Record_Explicitly_Written := State;
   end Set_Record_Explicitly_Written;

   function Get_Record_Explicitly_Written return Boolean is
   begin
      return Record_Explicitly_Written;
   end Get_Record_Explicitly_Written;

   procedure Spill_To_Disk is
   begin
      Store.Spill (Data_Table, "data", Current_Segment_Start);
   end Spill_To_Disk;

   procedure Spill_Output_To_Disk is
   begin
      Store.Spill (Output_Data_Table, "output_data", Output_Segment_Start);
   end Spill_Output_To_Disk;

end SData_Core.Table;