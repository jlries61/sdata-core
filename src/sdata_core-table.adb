--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Exceptions;
with SData_Core.Config;
with SData_Core.Signals;

with GNAT.OS_Lib;
with GNAT.Strings;
with Ada.Unchecked_Deallocation;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Table is

   use type Ada.Containers.Count_Type;

   --  Strip the leading space Integer'Image prepends for non-negative values
   --  so diagnostic strings read "rows=123" rather than "rows= 123".  Used
   --  only when building the structured context appended to spill / backing-
   --  store error messages.
   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;

   procedure Clear_Fetch_Cache is
   begin
      Seg_Cache.Clear;
      Seg_Start := 0;
      Seg_End   := 0;
   end Clear_Fetch_Cache;

   --  Rebuilds Column_Cursor_Cache to match Column_Order after any schema change.
   --  Must be called after every Insert/Delete/Rename on Data_Table or after a
   --  deep-copy assignment, since those operations may invalidate existing cursors.
   procedure Rebuild_Column_Cache is
   begin
      Column_Cursor_Cache.Clear;
      for I in 1 .. Natural (Column_Order.Length) loop
         Column_Cursor_Cache.Append
           (Data_Table.Find
              (Ada.Strings.Unbounded.To_String (Column_Order.Element (I))));
      end loop;
   end Rebuild_Column_Cache;

   procedure Rebuild_Output_Cache is
   begin
      Output_Cursor_Cache.Clear;
      for I in 1 .. Natural (Output_Column_Order.Length) loop
         Output_Cursor_Cache.Append
           (Output_Data_Table.Find
              (Ada.Strings.Unbounded.To_String (Output_Column_Order.Element (I))));
      end loop;
   end Rebuild_Output_Cache;

   procedure Spill_Output_To_Disk;
   procedure Spill_Table_To_Disk (T : aliased in out Column_Maps.Map; Table_Name : String; Start_Idx : Positive);

   function Sql_Id (Name : String) return String is
      Buf : String (1 .. Name'Length * 2);
      Len : Natural := 0;
   begin
      for C of Name loop
         Len := Len + 1;
         Buf (Len) := C;
         if C = ']' then
            Len := Len + 1;
            Buf (Len) := ']';
         end if;
      end loop;
      return "[" & Buf (1 .. Len) & "]";
   end Sql_Id;

   --------------
   -- Finalize --
   --------------
   overriding procedure Finalize (S : in out Backing_Store) is
      Success : Boolean;
   begin
      if not S.Is_Active then return; end if;
      --  Mark inactive first so a second call (explicit + automatic) is a no-op.
      S.Is_Active := False;
      SData_Core.Signals.Clear_Cleanup_Path;
      declare
         Path : constant String := Ada.Strings.Unbounded.To_String (S.Temp_Path);
      begin
         --  We avoid manually freeing S.DB here: doing so triggers a
         --  double-finalization crash inside Ada_Sqlite3 (observed with
         --  ada_sqlite3 0.1.1 -- the only published version; upstream
         --  github.com/gtnoble/ada-sqlite3 @ 2edbceb).  No upstream issue
         --  is filed as of 2026-06-02 and no fixed release exists.  The OS
         --  reclaims the memory; we only need to remove the file.  REVISIT
         --  when bumping ada_sqlite3 past 0.1.1 (see alire.toml): re-test
         --  whether freeing S.DB is safe and, if so, drop this leak.
         GNAT.OS_Lib.Delete_File (Path, Success);
      end;
      Seg_Cache.Clear;
      Seg_Start := 0;
      Seg_End   := 0;
   end Finalize;

   -- Filtered View Mapping
   type Index_Array_Access is access Index_Array;
   Filter_Map    : Index_Array_Access := null;

   -- BY-group variable names (upper-cased); mirrored from the interpreter.
   Table_By_Vars : Name_Vectors.Vector;

   -----------
   -- Clear --
   -----------
   procedure Clear is
   begin
      Finalize (Store);
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
      Upper_Name : constant String := Ada.Characters.Handling.To_Upper (Name);
      New_Col : Column;
   begin
      if Data_Table.Contains (Upper_Name) then
         return; 
      end if;
      
      New_Col.Name := (others => ' ');
      New_Col.Name (1 .. Upper_Name'Length) := Upper_Name;
      New_Col.Typ := Col_Type;
      
      --  Rule: New columns must match the existing table height.
      for I in 1 .. Table_Row_Count loop
         New_Col.Data.Append ((Kind => Val_Missing));
      end loop;
      
      Data_Table.Insert (Upper_Name, New_Col);
      Column_Order.Append (Ada.Strings.Unbounded.To_Unbounded_String (Upper_Name));

      --  Schema changed: invalidate segment cache and rebuild cursor cache.
      --  Insert may have triggered a rehash, invalidating all prior cursors.
      Clear_Fetch_Cache;
      Rebuild_Column_Cache;
   end Add_Column;

   ----------------
   -- Has_Column --
   ----------------
   function Has_Column (Name : String) return Boolean is
   begin
      return Data_Table.Contains (Ada.Characters.Handling.To_Upper (Name));
   end Has_Column;

   ---------------------
   -- Get_Column_Type --
   ---------------------
   function Get_Column_Type (Name : String) return Column_Type is
      Upper_Name : constant String := Ada.Characters.Handling.To_Upper (Name);
      Cursor : constant Column_Maps.Cursor := Data_Table.Find (Upper_Name);
   begin
      if not Column_Maps.Has_Element (Cursor) then
         raise Constraint_Error with
           "Get_Column_Type: column not found: " & Upper_Name;
      end if;
      return Column_Maps.Element (Cursor).Typ;
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
      return Ada.Strings.Unbounded.To_String (Column_Order.Element (I));
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

   function Get_Value_Upper (Row : Positive; Upper_Name : String) return Value is
      Cur : constant Column_Maps.Cursor := Data_Table.Find (Upper_Name);
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
            return Fetch_From_Disk (Row, Upper_Name);
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
            return (Kind => Val_Numeric, Num_Val => Float (Val.Int_Val));
         end if;
         raise Type_Mismatch_Error with "Expected Numeric for column " & Col_Name;
      elsif Col_Typ = Col_Integer and then Val.Kind /= Val_Integer then
         if Val.Kind = Val_Numeric then
            return (Kind => Val_Integer, Int_Val => Integer (Float'Truncation (Val.Num_Val)));
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
      Cur : constant Column_Maps.Cursor := Data_Table.Find (Upper_Name);
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
      Upper_Old : constant String := Ada.Characters.Handling.To_Upper (Old_Name);
      Upper_New : constant String := Ada.Characters.Handling.To_Upper (New_Name);
      Old_Pos   : Column_Maps.Cursor := Data_Table.Find (Upper_Old);
   begin
      if Column_Maps.Has_Element (Old_Pos)
         and then not Data_Table.Contains (Upper_New)
      then
         declare
            Col : Column := Column_Maps.Element (Old_Pos);
         begin
            Col.Name := (others => ' ');
            if Upper_New'Length > Max_Name_Len then
               Col.Name := Upper_New (Upper_New'First .. Upper_New'First + Max_Name_Len - 1);
            else
               Col.Name (1 .. Upper_New'Length) := Upper_New;
            end if;
            Data_Table.Delete (Old_Pos);
            Data_Table.Insert (Upper_New, Col);
            
            --  Data_Table is an unordered hash map, so Column_Order is the
            --  sole record of user-visible column sequence.  Patch the name
            --  in place rather than delete/re-append to preserve position.
            for I in 1 .. Natural (Column_Order.Length) loop
               if Ada.Strings.Unbounded.To_String (Column_Order.Element (I)) = Upper_Old then
                  Column_Order.Replace_Element (I, Ada.Strings.Unbounded.To_Unbounded_String (Upper_New));
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
      Upper_Name : constant String := Ada.Characters.Handling.To_Upper (Name);
      Pos : Column_Maps.Cursor := Data_Table.Find (Upper_Name);
   begin
      if Column_Maps.Has_Element (Pos) then
         Data_Table.Delete (Pos);
         for I in 1 .. Natural (Column_Order.Length) loop
            if Ada.Strings.Unbounded.To_String (Column_Order.Element (I)) = Upper_Name then
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
   
   ----------------------------------------------------------------
   --  Sort working storage with deterministic finalization.
   --
   --  Sort needs per-criterion value snapshots (Key_Data) and two scratch
   --  index arrays (Indices, Temp).  These were previously bare `access`
   --  allocations that leaked on every Sort call -- per-sort cost
   --  (key_columns + 2) * N * sizeof(Value | Positive), unbounded across
   --  repeated sorts in long-running sessions.
   --
   --  Wrapping each allocation in a Limited_Controlled holder makes the
   --  free deterministic: Finalize runs on scope exit, including the
   --  exception-unwind case.  Mirrors the Backing_Store pattern in this
   --  same package.
   ----------------------------------------------------------------
   type Sort_Key_Row is array (Natural range <>) of Value;
   type Sort_Key_Row_Access is access Sort_Key_Row;
   procedure Free_Key_Row is new Ada.Unchecked_Deallocation
      (Sort_Key_Row, Sort_Key_Row_Access);

   type Sort_Key_Holder is new Ada.Finalization.Limited_Controlled with record
      Ref : Sort_Key_Row_Access := null;
   end record;
   overriding procedure Finalize (H : in out Sort_Key_Holder);

   type Sort_Indices_Array is array (Positive range <>) of Natural;
   type Sort_Indices_Access is access Sort_Indices_Array;
   procedure Free_Sort_Indices is new Ada.Unchecked_Deallocation
      (Sort_Indices_Array, Sort_Indices_Access);

   type Sort_Indices_Holder is new Ada.Finalization.Limited_Controlled with record
      Ref : Sort_Indices_Access := null;
   end record;
   overriding procedure Finalize (H : in out Sort_Indices_Holder);

   overriding procedure Finalize (H : in out Sort_Key_Holder) is
   begin
      if H.Ref /= null then
         Free_Key_Row (H.Ref);
      end if;
   end Finalize;

   overriding procedure Finalize (H : in out Sort_Indices_Holder) is
   begin
      if H.Ref /= null then
         Free_Sort_Indices (H.Ref);
      end if;
   end Finalize;

   ----------
   -- Sort --
   ----------
   procedure Sort (Criteria : Sort_Criteria_Array) is
      N : constant Natural := Table_Row_Count;
   begin
      if N <= 1 or else Criteria'Length = 0 then return; end if;

      Clear_Fetch_Cache;

      if Store.Is_Active then
         Spill_To_Disk;
         declare
            N       : constant Natural := Column_Count;
            Cols_CSV : Ada.Strings.Unbounded.Unbounded_String;
            Col_Def  : Ada.Strings.Unbounded.Unbounded_String;
            OrderBy  : Ada.Strings.Unbounded.Unbounded_String :=
                          Ada.Strings.Unbounded.To_Unbounded_String (" ORDER BY ");
         begin
            if N = 0 then return; end if;

            for I in 1 .. N loop
               declare
                  Name  : constant String := Column_Name (I);  --  already upper-cased
                  Typ   : constant Column_Type := Data_Table.Element (Name).Typ;
                  SQL_T : constant String := (if Typ = Col_Numeric then "REAL"
                                              elsif Typ = Col_Integer then "INTEGER"
                                              else "TEXT");
               begin
                  Ada.Strings.Unbounded.Append (Cols_CSV, Sql_Id (Name));
                  Ada.Strings.Unbounded.Append (Col_Def,  Sql_Id (Name) & " " & SQL_T);
                  if I < N then
                     Ada.Strings.Unbounded.Append (Cols_CSV, ", ");
                     Ada.Strings.Unbounded.Append (Col_Def,  ", ");
                  end if;
               end;
            end loop;

            for I in Criteria'Range loop
               Ada.Strings.Unbounded.Append (OrderBy, Sql_Id (Ada.Characters.Handling.To_Upper (Criteria (I).Name (1 .. Criteria (I).Len))));
               if Criteria (I).Dir = Descending then Ada.Strings.Unbounded.Append (OrderBy, " DESC"); end if;
               if I < Criteria'Last then Ada.Strings.Unbounded.Append (OrderBy, ", "); end if;
            end loop;
            -- Ensure stability: use record_id as tie-breaker
            Ada.Strings.Unbounded.Append (OrderBy, ", record_id ASC");

            Store.DB.Execute ("CREATE TABLE data_new (record_id INTEGER PRIMARY KEY AUTOINCREMENT, " & Ada.Strings.Unbounded.To_String (Col_Def) & ")");
            Store.DB.Execute ("INSERT INTO data_new (" & Ada.Strings.Unbounded.To_String (Cols_CSV) & ") " &
                              "SELECT " & Ada.Strings.Unbounded.To_String (Cols_CSV) & " FROM data " & Ada.Strings.Unbounded.To_String (OrderBy));
            Store.DB.Execute ("DROP TABLE data");
            Store.DB.Execute ("ALTER TABLE data_new RENAME TO data");
         exception
            when E : SQLite_Error =>
               raise Script_Error with
                  "could not sort spilled dataset (disk full?)"
                  & " [rows=" & Img (Table_Row_Count)
                  & ", sort_keys=" & Img (Criteria'Length) & "]: "
                  & Ada.Exceptions.Exception_Message (E);
         end;
         return;
      end if;

      declare
         --  Per-criterion value snapshots and scratch index arrays are held
         --  in Limited_Controlled wrappers so heap allocations are freed on
         --  scope exit (including exception unwind).  See holder type
         --  declarations above Sort.
         Key_Data : array (Criteria'Range) of Sort_Key_Holder;
         Indices  : Sort_Indices_Holder;
         Temp     : Sort_Indices_Holder;

         function Lt (L, R : Natural) return Boolean is
         begin
            for C in Criteria'Range loop
               declare
                  VL : Value renames Key_Data (C).Ref (L);
                  VR : Value renames Key_Data (C).Ref (R);
               begin
                  if VL /= VR then
                     if Criteria (C).Dir = Ascending then
                        return VL < VR;
                     else
                        return VR < VL;
                     end if;
                  end if;
               end;
            end loop;
            return L < R;
         end Lt;

         procedure Merge_Sort (Lo, Hi : Positive) is
            Mid : Positive;
            I, J, K : Positive;
         begin
            if Lo >= Hi then return; end if;
            Mid := Lo + (Hi - Lo) / 2;
            Merge_Sort (Lo, Mid);
            Merge_Sort (Mid + 1, Hi);
            for X in Lo .. Hi loop Temp.Ref (X) := Indices.Ref (X); end loop;
            I := Lo; J := Mid + 1; K := Lo;
            while I <= Mid and then J <= Hi loop
               if not Lt (Temp.Ref (J), Temp.Ref (I)) then
                  Indices.Ref (K) := Temp.Ref (I); I := I + 1;
               else
                  Indices.Ref (K) := Temp.Ref (J); J := J + 1;
               end if;
               K := K + 1;
            end loop;
            while I <= Mid loop Indices.Ref (K) := Temp.Ref (I); I := I + 1; K := K + 1; end loop;
         end Merge_Sort;

      begin
         for C in Criteria'Range loop
            declare
               Col_Name : constant String :=
                  Ada.Characters.Handling.To_Upper (Criteria (C).Name (1 .. Criteria (C).Len));
            begin
               Key_Data (C).Ref := new Sort_Key_Row (0 .. N);
               Key_Data (C).Ref (0) := (Kind => Val_Missing);
               if Data_Table.Contains (Col_Name) then
                  for R in 1 .. N loop
                     Key_Data (C).Ref (R) := Get_Value_Upper (R, Col_Name);
                  end loop;
               else
                  for R in 1 .. N loop
                     Key_Data (C).Ref (R) := (Kind => Val_Missing);
                  end loop;
               end if;
            end;
         end loop;

         Indices.Ref := new Sort_Indices_Array (1 .. N);
         Temp.Ref    := new Sort_Indices_Array (1 .. N);
         for I in 1 .. N loop Indices.Ref (I) := I; end loop;

         Merge_Sort (1, N);

         declare
            Pos : Column_Maps.Cursor := Data_Table.First;
         begin
            while Column_Maps.Has_Element (Pos) loop
               declare
                  Current_Key : constant String := Column_Maps.Key (Pos);
                  Old_Data    : Value_Vectors.Vector renames Data_Table.Reference (Pos).Element.all.Data;
                  New_Data    : Value_Vectors.Vector;
               begin
                  New_Data.Reserve_Capacity (Ada.Containers.Count_Type (N));
                  for I in 1 .. N loop
                     New_Data.Append (Get_Value_Upper (Indices.Ref (I), Current_Key));
                  end loop;
                  Value_Vectors.Move (Source => New_Data, Target => Old_Data);
               end;
               Column_Maps.Next (Pos);
            end loop;
         end;
      end;
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
      Table_By_Vars.Append (To_Unbounded_String (Name));
   end Add_By_Var;

   function By_Var_Count return Natural is
   begin
      return Natural (Table_By_Vars.Length);
   end By_Var_Count;

   function By_Var_Name (I : Positive) return String is
   begin
      return To_String (Table_By_Vars.Element (I));
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
            Name : constant String := To_String (V);
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
      if Store.Is_Active then
         return Ada.Strings.Unbounded.To_String (Store.Temp_Path);
      else
         return "";
      end if;
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
         Store.DB.Execute ("DROP TABLE IF EXISTS output_data");
      end if;
      Rebuild_Output_Cache;
   end Initialize_Output_Table;

   procedure Add_Output_Column (Name : String; Col_Type : Column_Type) is
      Upper_Name : constant String := Ada.Characters.Handling.To_Upper (Name);
      New_Col : Column;
   begin
      if Output_Data_Table.Contains (Upper_Name) then return; end if;
      New_Col.Name := (others => ' ');
      New_Col.Name (1 .. Upper_Name'Length) := Upper_Name;
      New_Col.Typ := Col_Type;

      for I in 1 .. Output_Table_Row_Count loop
         New_Col.Data.Append ((Kind => Val_Missing));
      end loop;

      Output_Data_Table.Insert (Upper_Name, New_Col);
      Output_Column_Order.Append (Ada.Strings.Unbounded.To_Unbounded_String (Upper_Name));
      --  Insert may have triggered a rehash; rebuild output cursor cache.
      Rebuild_Output_Cache;
   end Add_Output_Column;

   procedure Add_Output_Row is
   begin
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

   procedure Set_Output_Value_Upper (Row : Positive; Upper_Name : String; Val : Value) is
      Cur : constant Column_Maps.Cursor := Output_Data_Table.Find (Upper_Name);
   begin
      if not Column_Maps.Has_Element (Cur) then
         return;
      end if;
      declare
         Ref : constant Column_Maps.Reference_Type :=
            Output_Data_Table.Reference (Cur);
         Col : Column renames Ref.Element.all;
      begin
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
      Clear_Fetch_Cache;
      if Output_Table_Row_Count = 0 and then Output_Data_Table.Is_Empty
        and then not Data_Table.Is_Empty
      then
         for Pos in Data_Table.Iterate loop
            declare
               Col : Column := Column_Maps.Element (Pos);
            begin
               Col.Data.Clear;
               Data_Table.Replace_Element (Pos, Col);
            end;
         end loop;
         Table_Row_Count := 0;
         if Store.Is_Active then
            Store.DB.Execute ("DROP TABLE IF EXISTS data");
            Store.DB.Execute ("DROP TABLE IF EXISTS output_data");
         end if;
      else
         Data_Table := Output_Data_Table;
         Column_Order := Output_Column_Order;
         Table_Row_Count := Output_Table_Row_Count;
         --  Deep copy creates a new map; all prior Column_Cursor_Cache cursors are
         --  invalid.  Rebuild immediately before any caller can use Get_Value_By_Col.
         Rebuild_Column_Cache;

         if Store.Is_Active then
            Store.DB.Execute ("DROP TABLE IF EXISTS data");
            if Output_Spilled then
               Spill_Output_To_Disk;
               Store.DB.Execute ("ALTER TABLE output_data RENAME TO data");
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
            return Fetch_From_Disk (Row, Column_Maps.Key (Cur));
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Get_Value_By_Col;

   ------------------------------
   -- Set_Output_Value_By_Col --
   ------------------------------
   procedure Set_Output_Value_By_Col (Row : Positive; Col_Pos : Positive; Val : Value) is
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
         Col.Data.Replace_Element
           (Row - Output_Segment_Start + 1,
            Coerce_Value (Val, Col.Typ, Column_Maps.Key (Cur)));
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

   ------------------------------
   -- Initialize_Backing_Store --
   ------------------------------
   procedure Initialize_Backing_Store is
      FD : GNAT.OS_Lib.File_Descriptor;
      Temp_Name : GNAT.Strings.String_Access;
   begin
      if Store.Is_Active then return; end if;
      GNAT.OS_Lib.Create_Temp_File (FD, Temp_Name);
      GNAT.OS_Lib.Close (FD);
      Store.Temp_Path := Ada.Strings.Unbounded.To_Unbounded_String (Temp_Name.all);
      Store.DB := new Ada_Sqlite3.Database'(Ada_Sqlite3.Open (Temp_Name.all));
      --  This is a process-private temp file; we need no durability at all.
      --  Disable the journal and fsync entirely, and give SQLite a large page
      --  cache so that external-merge sort runs stay hot across passes.
      --  temp_store=MEMORY keeps SQLite's own sort intermediates in RAM.
      Store.DB.Execute ("PRAGMA journal_mode = OFF");
      Store.DB.Execute ("PRAGMA synchronous = OFF");
      Store.DB.Execute ("PRAGMA cache_size = -65536");  --  64 MB (negative = KiB)
      Store.DB.Execute ("PRAGMA temp_store = MEMORY");
      Store.Is_Active := True;
      SData_Core.Signals.Register_Cleanup_Path (Temp_Name.all);
      GNAT.Strings.Free (Temp_Name);
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not create disk backing store for dataset"
            & " [temp_path="
            & Ada.Strings.Unbounded.To_String (Store.Temp_Path) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Initialize_Backing_Store;

   ---------------------------
   -- Spill_Table_To_Disk --
   ---------------------------
   --  Write every in-memory row of T to the [Table_Name] SQLite table in a
   --  single transaction, then clear the in-memory column vectors.  Shared
   --  by Spill_To_Disk ("data") and Spill_Output_To_Disk ("output_data").
   --
   --  Atomicity / failure contract -- this is an all-or-nothing operation
   --  with a deliberate CLEAN-ABORT guarantee:
   --
   --    * Success: rows are committed, then the in-memory Data vectors are
   --      cleared (the "for Pos in T.Iterate ... Data.Clear" below) and the
   --      caller advances Current_Segment_Start past the spilled segment.
   --
   --    * SQLite_Error (e.g. disk full) anywhere in BEGIN..COMMIT: SQLite
   --      rolls back the uncommitted transaction, so nothing reaches disk;
   --      the in-memory Clear is SKIPPED, so memory still holds every row;
   --      and the caller (Add_Row / Commit_Output_Table) unwinds before
   --      touching Current_Segment_Start or Table_Row_Count.  The net
   --      result is the exact pre-call state -- the table stays fully
   --      readable from memory -- with the failure surfaced as Script_Error.
   --
   --  WARNING: do NOT "fix" this by forcing the in-memory Clear to run on
   --  the exception path (e.g. wrapping it in a controlled type).  Binding
   --  only READS the Value vectors; on failure they are the sole surviving
   --  copy of the data.  Clearing them after a failed write would discard
   --  live rows -- turning a recoverable disk-full into data loss.
   --
   --  A failed FIRST spill leaves Store.Is_Active = True (set by
   --  Initialize_Backing_Store before the write).  This is benign and is
   --  intentionally NOT unwound: reads still hit the in-memory segment,
   --  Initialize_Backing_Store is idempotent so no temp file leaks, the
   --  temp file is registered for cleanup, and freeing Store.DB here would
   --  court the ada_sqlite3 double-finalize crash that Finalize deliberately
   --  avoids (see :91-92).
   procedure Spill_Table_To_Disk (T : aliased in out Column_Maps.Map; Table_Name : String; Start_Idx : Positive) is
      SQL : Ada.Strings.Unbounded.Unbounded_String;
      Memory_Rows : Natural := 0;
      package Name_Vecs is new Ada.Containers.Vectors (Positive, Ada.Strings.Unbounded.Unbounded_String);
      package Cursor_Vecs is new Ada.Containers.Vectors (Positive, Column_Maps.Cursor, Column_Maps."=");
      Col_Names   : Name_Vecs.Vector;
      Col_Cursors : Cursor_Vecs.Vector;
   begin
      if T.Is_Empty then return; end if;

      --  Clear cache because we might be modifying the table being cached.
      Clear_Fetch_Cache;
      for Pos in T.Iterate loop
         Col_Names.Append (Ada.Strings.Unbounded.To_Unbounded_String (Column_Maps.Key (Pos)));
         Col_Cursors.Append (Pos);
         if Memory_Rows = 0 then
            Memory_Rows := Natural (Column_Maps.Constant_Reference (T, Pos).Element.all.Data.Length);
         end if;
      end loop;
      if Memory_Rows = 0 then return; end if;
      Initialize_Backing_Store;
      
      SQL := Ada.Strings.Unbounded.To_Unbounded_String ("CREATE TABLE IF NOT EXISTS [" & Table_Name & "] (record_id INTEGER PRIMARY KEY");
      for C in 1 .. Natural (Col_Names.Length) loop
         declare
            Ref   : constant Column_Maps.Constant_Reference_Type :=
               Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
            SQL_T : constant String := (if Ref.Element.all.Typ = Col_Numeric then "REAL"
                                        elsif Ref.Element.all.Typ = Col_Integer then "INTEGER"
                                        else "TEXT");
         begin
            Ada.Strings.Unbounded.Append (SQL, ", " & Sql_Id (Ada.Strings.Unbounded.To_String (Col_Names.Element (C))) & " " & SQL_T);
         end;
      end loop;
      Ada.Strings.Unbounded.Append (SQL, ")");
      Store.DB.Execute (Ada.Strings.Unbounded.To_String (SQL));

      SQL := Ada.Strings.Unbounded.To_Unbounded_String ("INSERT OR REPLACE INTO [" & Table_Name & "] (record_id");
      for Name of Col_Names loop Ada.Strings.Unbounded.Append (SQL, ", " & Sql_Id (Ada.Strings.Unbounded.To_String (Name))); end loop;
      Ada.Strings.Unbounded.Append (SQL, ") VALUES (?");
      for I in 1 .. Natural (Col_Names.Length) loop Ada.Strings.Unbounded.Append (SQL, ", ?"); end loop;
      Ada.Strings.Unbounded.Append (SQL, ")");

      declare
         Stmt : Ada_Sqlite3.Statement := Store.DB.Prepare (Ada.Strings.Unbounded.To_String (SQL));
      begin
         --  Batch all inserts in one transaction; without this, SQLite
         --  auto-commits each row individually, causing O(N) lock cycles.
         Store.DB.Execute ("BEGIN");
         for R in 1 .. Memory_Rows loop
            Stmt.Reset;
            Stmt.Clear_Bindings;
            Stmt.Bind_Int (1, Start_Idx + R - 1);
            for C in 1 .. Natural (Col_Names.Length) loop
               declare
                  Ref : constant Column_Maps.Constant_Reference_Type :=
                     Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
                  Val : constant Value := Ref.Element.all.Data.Element (R);
               begin
                  case Val.Kind is
                     when Val_Numeric => Stmt.Bind_Double (C + 1, Val.Num_Val);
                     when Val_Integer => Stmt.Bind_Int (C + 1, Val.Int_Val);
                     when Val_String  => Stmt.Bind_Text (C + 1, Ada.Strings.Unbounded.To_String (Val.Str_Val));
                     when Val_Missing => Stmt.Bind_Null (C + 1);
                  end case;
               end;
            end loop;
            Stmt.Step;
         end loop;
         Store.DB.Execute ("COMMIT");
      end;

      for Pos in T.Iterate loop T.Reference (Pos).Element.all.Data.Clear; end loop;
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not write dataset to disk (disk full?)"
            & " [table=" & Table_Name
            & ", rows=" & Img (Memory_Rows)
            & ", segment_start=" & Img (Start_Idx) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Spill_Table_To_Disk;

   procedure Spill_To_Disk is
   begin
      Spill_Table_To_Disk (Data_Table, "data", Current_Segment_Start);
   end Spill_To_Disk;

   procedure Spill_Output_To_Disk is
   begin
      Spill_Table_To_Disk (Output_Data_Table, "output_data", Output_Segment_Start);
   end Spill_Output_To_Disk;

   -----------------------
   -- Fetch_From_Disk --
   -----------------------
   function Fetch_From_Disk (Row : Positive; Col_Name : String) return Value is
      U_Col : constant String := Ada.Characters.Handling.To_Upper (Col_Name);
   begin
      --  Load a new segment when Row falls outside the cached range.
      if Seg_Start = 0 or else Row < Seg_Start or else Row > Seg_End then
         declare
            Col_Count : constant Positive := Positive'Max (1, Natural (Data_Table.Length));
            Limit   : constant Positive :=
               (if SData_Core.Config.Max_Table_Cells > 0
                then Positive'Max (1, SData_Core.Config.Max_Table_Cells / Col_Count)
                else 1);
            S_Idx   : constant Natural  := (Row - 1) / Limit;
            S_Start : constant Positive := S_Idx * Limit + 1;
            S_End   : constant Positive :=
               Positive'Min (S_Start + Limit - 1, Table_Row_Count);
            Num_Rows : constant Natural := S_End - S_Start + 1;
            Stmt : Ada_Sqlite3.Statement := Store.DB.Prepare
               ("SELECT * FROM [data] WHERE record_id >= ? AND record_id <= ?" &
                " ORDER BY record_id");
            Num_Cols : Integer;
         begin
            Stmt.Bind_Int (1, S_Start);
            Stmt.Bind_Int (2, S_End);
            Seg_Cache.Clear;

            --  Column count is known from the prepared statement before stepping.
            Num_Cols := Stmt.Column_Count - 1;  --  exclude record_id at index 0

            --  Pre-insert an empty vector for each data column and reserve
            --  capacity so that subsequent Appends do not reallocate.
            for I in 1 .. Num_Cols loop
               declare
                  CName : constant String          := Stmt.Column_Name (I);
                  Empty : constant Value_Vectors.Vector := Value_Vectors.Empty_Vector;
               begin
                  Seg_Cache.Include (CName, Empty);
                  Seg_Cache.Reference (CName).Reserve_Capacity
                     (Ada.Containers.Count_Type (Num_Rows));
               end;
            end loop;

            --  Fetch all rows in one sequential scan.
            while Stmt.Step = Ada_Sqlite3.ROW loop
               for I in 1 .. Num_Cols loop
                  declare
                     CName : constant String               := Stmt.Column_Name (I);
                     Typ   : constant Ada_Sqlite3.Column_Type := Stmt.Get_Column_Type (I);
                     Val   : Value;
                  begin
                     if Stmt.Column_Is_Null (I) then
                        Val := (Kind => Val_Missing);
                     elsif Typ = Ada_Sqlite3.Float_Type then
                        Val := (Kind => Val_Numeric, Num_Val => Stmt.Column_Double (I));
                     elsif Typ = Ada_Sqlite3.Integer_Type then
                        Val := (Kind => Val_Integer, Int_Val => Stmt.Column_Int (I));
                     else
                        Val := (Kind    => Val_String,
                                Str_Val => Ada.Strings.Unbounded.To_Unbounded_String
                                             (Stmt.Column_Text (I)));
                     end if;
                     Seg_Cache.Reference (CName).Append (Val);
                  end;
               end loop;
            end loop;

            Seg_Start := S_Start;
            Seg_End   := S_End;
         end;
      end if;

      --  Return the cached value.
      if Seg_Cache.Contains (U_Col) then
         declare
            Idx : constant Positive := Row - Seg_Start + 1;
            Ref : constant Seg_Data_Maps.Constant_Reference_Type :=
               Seg_Cache.Constant_Reference (U_Col);
         begin
            if Idx <= Natural (Ref.Length) then
               return Ref.Element (Idx);
            end if;
         end;
      end if;
      return (Kind => Val_Missing);
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not read dataset from disk "
            & "(backing store corrupted or missing?)"
            & " [row=" & Img (Row)
            & ", column=" & U_Col & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Fetch_From_Disk;

end SData_Core.Table;