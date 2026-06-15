--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;
with SData_Core.IO;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Sorting is

   --  SQLite identifier quoter for the spilled ORDER BY.  Backing_Store keeps
   --  its own private copy for the spill/fetch path; duplicate the 9-line
   --  quoter here rather than widen the Backing_Store API for one caller.
   --  (If a third caller appears, promote it to Columns.)
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
   --  exception-unwind case.  Mirrors the Backing_Store pattern.
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
   procedure Sort
     (T             : in out Columns.Column_Maps.Map;
      Column_Order  : Columns.Column_Name_Vectors.Vector;
      Criteria      : Columns.Sort_Criteria_Array;
      Row_Count     : Natural;
      Segment_Start : Positive;
      Store         : in out Backing_Store.Backing_Store)
   is
      N : constant Natural := Row_Count;

      --  Local value reader for the in-memory key snapshot.  The in-memory
      --  path runs only when the store is NOT active, so Segment_Start = 1 and
      --  the cell is Data.Element (Row).  Mirrors the old Get_Value_Upper for
      --  the not-spilled case exactly (out-of-segment => Missing).
      function Cell (Row : Positive; Key : Columns.Column_Name) return Value is
         Cur : constant Columns.Column_Maps.Cursor := T.Find (Key);
      begin
         if not Columns.Column_Maps.Has_Element (Cur) then
            return (Kind => Val_Missing);
         end if;
         declare
            Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
               T.Constant_Reference (Cur);
            Len : constant Natural := Natural (Ref.Element.all.Data.Length);
         begin
            if Row >= Segment_Start and then Row < Segment_Start + Len then
               return Ref.Element.all.Data.Element (Row - Segment_Start + 1);
            else
               return (Kind => Val_Missing);
            end if;
         end;
      end Cell;
   begin
      if N <= 1 or else Criteria'Length = 0 then return; end if;

      --  One-shot progress note (sort is atomic from the caller's view);
      --  no-op unless --progress is set.
      SData_Core.IO.Show_Progress ("SORT", N, Final => True);

      Store.Clear_Cache;

      if Store.Is_Active then
         Store.Spill (T, "data", Segment_Start);
         declare
            Col_N    : constant Natural := Natural (T.Length);
            Cols_CSV : Unbounded_String;
            Col_Def  : Unbounded_String;
            OrderBy  : Unbounded_String := To_Unbounded_String (" ORDER BY ");
         begin
            if Col_N = 0 then return; end if;

            for I in 1 .. Col_N loop
               declare
                  Key   : constant Columns.Column_Name := Column_Order.Element (I);
                  Name  : constant String := Columns.Image (Key);
                  Typ   : constant Columns.Column_Type :=
                     T.Constant_Reference (T.Find (Key)).Element.all.Typ;
                  SQL_T : constant String := (if Typ = Col_Numeric then "REAL"
                                              elsif Typ = Col_Integer then "INTEGER"
                                              else "TEXT");
               begin
                  Append (Cols_CSV, Sql_Id (Name));
                  Append (Col_Def,  Sql_Id (Name) & " " & SQL_T);
                  if I < Col_N then
                     Append (Cols_CSV, ", ");
                     Append (Col_Def,  ", ");
                  end if;
               end;
            end loop;

            for I in Criteria'Range loop
               Append (OrderBy, Sql_Id (Ada.Characters.Handling.To_Upper
                       (Criteria (I).Name (1 .. Criteria (I).Len))));
               if Criteria (I).Dir = Descending then Append (OrderBy, " DESC"); end if;
               if I < Criteria'Last then Append (OrderBy, ", "); end if;
            end loop;
            --  Ensure stability: use record_id as tie-breaker
            Append (OrderBy, ", record_id ASC");

            Store.Execute ("CREATE TABLE data_new (record_id INTEGER PRIMARY KEY AUTOINCREMENT, "
                           & To_String (Col_Def) & ")");
            Store.Execute ("INSERT INTO data_new (" & To_String (Cols_CSV) & ") "
                           & "SELECT " & To_String (Cols_CSV) & " FROM data "
                           & To_String (OrderBy));
            Store.Execute ("DROP TABLE data");
            Store.Execute ("ALTER TABLE data_new RENAME TO data");
         exception
            when E : SQLite_Error =>
               raise Script_Error with
                  "could not sort spilled dataset (disk full?)"
                  & " [rows=" & Columns.Img (N)
                  & ", sort_keys=" & Columns.Img (Criteria'Length) & "]: "
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
               Key : constant Columns.Column_Name :=
                  To_Column_Name (Criteria (C).Name (1 .. Criteria (C).Len));
            begin
               Key_Data (C).Ref := new Sort_Key_Row (0 .. N);
               Key_Data (C).Ref (0) := (Kind => Val_Missing);
               if T.Contains (Key) then
                  for R in 1 .. N loop
                     Key_Data (C).Ref (R) := Cell (R, Key);
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
            Pos : Columns.Column_Maps.Cursor := T.First;
         begin
            while Columns.Column_Maps.Has_Element (Pos) loop
               declare
                  --  Read the reordered column's value vector directly through
                  --  the cursor: the in-memory path has Segment_Start = 1, so
                  --  row I maps to Old_Data.Element (I) -- no Image round-trip,
                  --  no key construction, no Find per cell (M2 follow-up #1).
                  Old_Data : Value_Vectors.Vector renames
                     T.Reference (Pos).Element.all.Data;
                  New_Data : Value_Vectors.Vector;
               begin
                  New_Data.Reserve_Capacity (Ada.Containers.Count_Type (N));
                  for I in 1 .. N loop
                     New_Data.Append (Old_Data.Element (Indices.Ref (I)));
                  end loop;
                  Value_Vectors.Move (Source => New_Data, Target => Old_Data);
               end;
               Columns.Column_Maps.Next (Pos);
            end loop;
         end;
      end;
   end Sort;

end SData_Core.Sorting;
