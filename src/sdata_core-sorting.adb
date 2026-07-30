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

   --  Quote Name as a SQLite identifier for the spilled ORDER BY: wrap it in
   --  [ ] and escape any embedded ']' by doubling it (the sole metacharacter
   --  inside a bracket-quoted identifier), so column names with spaces,
   --  punctuation, or SQL keywords are safe.  Buf is sized Name'Length * 2 for
   --  the worst case of all-']'.  Backing_Store keeps its own private copy for
   --  the spill/fetch path; this 9-line quoter is duplicated rather than
   --  widening the Backing_Store API for one caller.  (If a third caller
   --  appears, promote it to Columns.)
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

         if Store.Is_EAV then
            --  EAV disk-path rebuild (ADR-0011). Cannot ORDER BY a sort key
            --  directly -- it's spread across rows, not present as a SQL
            --  column -- so: pivot only the active sort-key columns (always
            --  a small, bounded set) via one plain LEFT JOIN per key
            --  (benchmarked 2026-07-29b: no SQL index of any kind beats
            --  every indexed alternative for this exact access pattern, see
            --  ADR-0011's second Amendment); assemble a full 1..N record_id
            --  sequence via a recursive CTE rather than a
            --  SELECT DISTINCT record_id FROM data (which would silently
            --  drop any record whose every column is Missing -- such a
            --  record has zero physical EAV rows); rank by
            --  ROW_NUMBER() OVER the sort keys; copy every EAV cell into
            --  data_new reassigned to its new record_id; swap in exactly
            --  the same drop/rename pattern as the Wide path below.
            declare
               Joins   : Unbounded_String;
               OrderBy : Unbounded_String;
            begin
               for I in Criteria'Range loop
                  declare
                     Key_Name : constant String := Ada.Characters.Handling.To_Upper
                        (Criteria (I).Name (1 .. Criteria (I).Len));
                     Cid   : constant Natural := Store.Col_Id ("data", Key_Name);
                     Alias : constant String := "k" & Columns.Img (I);
                  begin
                     --  Cid = 0: the sort key was never spilled under this
                     --  name -- either it's genuinely not a column of T (see
                     --  below for how that's reachable at all: the
                     --  interpreter's undefined-variable guard for SORT is
                     --  gated on Column_Count > 0, so a REPEAT step whose
                     --  Column_Count is still 0 -- e.g. no LET ever fired for
                     --  any record -- lets SORT reference a name that plain
                     --  never exists; confirmed reviewer question on PR #101),
                     --  or it once was a column, spilled, and was DROPped
                     --  back out (Drop_Column never touches the spill store,
                     --  so a dropped column's col_id simply stops being
                     --  reachable via T without ever being reachable via
                     --  Store either). Either way, matches the in-memory
                     --  path's tolerant treatment of an unknown key as
                     --  all-Missing (see Cell, above) by simply contributing
                     --  no join/order term for it.
                     if Cid > 0 then
                        Append
                          (Joins,
                           " LEFT JOIN (SELECT record_id, val_num, val_int, val_txt " &
                           "FROM data WHERE col_id = " & Columns.Img (Cid) & ") " &
                           Alias & " ON " & Alias & ".record_id = seq.record_id");
                        declare
                           Key_Col : constant Columns.Column_Name := To_Column_Name (Key_Name);
                           Typ : constant Columns.Column_Type :=
                              (if T.Contains (Key_Col)
                               then T.Constant_Reference (T.Find (Key_Col)).Element.all.Typ
                               else Col_Numeric);
                           Expr : constant String :=
                              (if Typ = Col_Numeric then Alias & ".val_num"
                               elsif Typ = Col_Integer then Alias & ".val_int"
                               else Alias & ".val_txt");
                        begin
                           if Length (OrderBy) > 0 then Append (OrderBy, ", "); end if;
                           Append (OrderBy, Expr);
                           if Criteria (I).Dir = Descending then Append (OrderBy, " DESC"); end if;
                        end;
                     end if;
                  end;
               end loop;
               if Length (OrderBy) > 0 then Append (OrderBy, ", "); end if;
               Append (OrderBy, "seq.record_id ASC");

               Store.Execute
                 ("CREATE TABLE data_new (record_id INTEGER, col_id INTEGER, " &
                  "val_num REAL, val_int INTEGER, val_txt TEXT, " &
                  "PRIMARY KEY (record_id, col_id)) WITHOUT ROWID");
               Store.Execute
                 ("INSERT INTO data_new (record_id, col_id, val_num, val_int, val_txt) " &
                  "SELECT rn.new_id, v.col_id, v.val_num, v.val_int, v.val_txt " &
                  "FROM data v JOIN (" &
                  "WITH RECURSIVE seq(record_id) AS (SELECT 1 UNION ALL " &
                  "SELECT record_id + 1 FROM seq WHERE record_id < " & Columns.Img (N) & ") " &
                  "SELECT seq.record_id AS record_id, " &
                  "ROW_NUMBER() OVER (ORDER BY " & To_String (OrderBy) & ") AS new_id " &
                  "FROM seq" & To_String (Joins) &
                  ") rn ON rn.record_id = v.record_id");
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
