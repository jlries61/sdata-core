--  BENCHMARK SPIKE -- not a correctness test, not part of run-tests.sh.
--
--  Compares the CURRENT wide-table SQLite disk-spill schema (one SQL column
--  per data column, SData_Core.Backing_Store) against the ADOPTED
--  entity-attribute-value (EAV) schema from ADR-0011
--  (docs/decisions/ADR-0011-eav-disk-spill-schema.md), for the ~2000-column
--  spill ceiling removal tracked as jlries61/sdata#64, and then benchmarks
--  the one open question the ADR's 2026-07-29 amendment left unresolved:
--  how should Sorting's sort-key pivot ("all values of column X across
--  every record") be served now that the schema carries no persistent
--  secondary index?
--
--  HISTORY: the first version of this driver ran the full Wide-vs-EAV
--  insert/fetch/size comparison (results committed in
--  tests/spill_schema_benchmark_results.csv) and, as a follow-up, isolated
--  a catastrophic insert-time cliff to the EAV schema's original
--  [<name>_by_col] (col_id, record_id) secondary index (results in
--  tests/spill_schema_benchmark_followup.csv; see ADR-0011's Amendment
--  section for the full analysis). That index is now gone from the
--  schema this driver builds -- EAV always means the amended, index-free
--  design below. This version instead measures the three candidate
--  strategies for Sorting's sort-key pivot access pattern.
--
--  Build: alr exec -- gprbuild -P tests/sdata_core_tests.gpr
--  Run (from the sdata-core repo root, so the results CSV lands under
--  tests/): tests/bin/spill_schema_benchmark
--
--  Uses the real Ada_Sqlite3 / Ada_Sqlite3.Wide bindings and the same
--  connection PRAGMAs as SData_Core.Backing_Store.Open, so results reflect
--  the actual production code path as closely as a standalone driver can.
--  Every table in this benchmark is all-Val_Numeric for simplicity (real
--  tables mix Numeric/Integer/Character); the per-cell structural overhead
--  this measures (row/PK/index bookkeeping) doesn't depend materially on
--  which of val_num/val_int/val_txt a cell populates.

with Ada.Text_IO;             use Ada.Text_IO;
with Ada.Calendar;            use Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada_Sqlite3;             use Ada_Sqlite3;
with Ada_Sqlite3.Wide;

procedure Spill_Schema_Benchmark is

   type Database_Access is access all Ada_Sqlite3.Database;

   type Integer_Array is array (Positive range <>) of Integer;

   Results_Path : constant String := "tests/spill_schema_benchmark_sortpivot.csv";
   Results_File : File_Type;

   --------------------------------------------------------------------
   --  Small helpers
   --------------------------------------------------------------------

   function Trim_Img (N : Long_Integer) return String is
      S : constant String := Long_Integer'Image (N);
   begin
      if S'Length > 0 and then S (S'First) = ' ' then
         return S (S'First + 1 .. S'Last);
      else
         return S;
      end if;
   end Trim_Img;

   function Trim_Img (N : Integer) return String is
     (Trim_Img (Long_Integer (N)));

   function Ms_Img (D : Duration) return String is
     (Trim_Img (Long_Integer (Long_Float (D) * 1000.0)));

   --  Deterministic pseudo-uniform "is this cell missing" decision, so the
   --  benchmark is reproducible without a random-number dependency.
   function Is_Missing (Row, Col, Sparsity_Pct : Integer) return Boolean is
     (((Row * 31 + Col * 17) mod 100) < Sparsity_Pct);

   function Cell_Value (Row, Col : Integer) return Long_Float is
     (Long_Float (Row) + Long_Float (Col) / 1000.0);

   function New_Temp_Path return String is
      FD   : GNAT.OS_Lib.File_Descriptor;
      Name : GNAT.Strings.String_Access;
   begin
      GNAT.OS_Lib.Create_Temp_File (FD, Name);
      GNAT.OS_Lib.Close (FD);
      declare
         Result : constant String := Name.all;
      begin
         GNAT.Strings.Free (Name);
         return Result;
      end;
   end New_Temp_Path;

   function Open_Bench_DB (Path : String) return Database_Access is
      DB : constant Database_Access :=
         new Ada_Sqlite3.Database'(Ada_Sqlite3.Open (Path));
   begin
      --  Same PRAGMAs as SData_Core.Backing_Store.Open: process-private
      --  temp file, no durability needed.
      DB.Execute ("PRAGMA journal_mode = OFF");
      DB.Execute ("PRAGMA synchronous = OFF");
      DB.Execute ("PRAGMA cache_size = -65536");
      DB.Execute ("PRAGMA temp_store = MEMORY");
      return DB;
   end Open_Bench_DB;

   procedure Cleanup (Path : String) is
      Success : Boolean;
   begin
      --  Deliberately do not free DB's heap allocation -- mirrors
      --  Backing_Store.Close's documented workaround for a double-
      --  finalization crash in ada_sqlite3 0.1.1. Trivial leak across a
      --  few benchmark iterations; reclaimed at process exit.
      GNAT.OS_Lib.Delete_File (Path, Success);
   end Cleanup;

   --------------------------------------------------------------------
   --  EAV (adopted, ADR-0011 as amended 2026-07-29) shape -- no
   --  persistent secondary index.
   --------------------------------------------------------------------

   procedure Build_EAV_Schema (DB : Database_Access) is
   begin
      DB.Execute
        ("CREATE TABLE data_cols (col_id INTEGER PRIMARY KEY, " &
         "col_name TEXT UNIQUE NOT NULL)");
      DB.Execute
        ("CREATE TABLE data (record_id INTEGER NOT NULL, col_id INTEGER NOT NULL, " &
         "val_num REAL, val_int INTEGER, val_txt TEXT, " &
         "PRIMARY KEY (record_id, col_id)) WITHOUT ROWID");
   end Build_EAV_Schema;

   procedure Populate_EAV_Cols (DB : Database_Access; Cols : Integer) is
      Stmt : Statement := DB.Prepare ("INSERT INTO data_cols (col_id, col_name) VALUES (?, ?)");
   begin
      DB.Execute ("BEGIN");
      for C in 1 .. Cols loop
         Stmt.Reset;
         Stmt.Clear_Bindings;
         Stmt.Bind_Int (1, C);
         Stmt.Bind_Text (2, "C" & Trim_Img (C));
         Stmt.Step;
      end loop;
      DB.Execute ("COMMIT");
   end Populate_EAV_Cols;

   function Insert_EAV
     (DB : Database_Access; Rows, Cols, Sparsity_Pct : Integer) return Duration
   is
      Stmt : Statement :=
         DB.Prepare ("INSERT INTO data (record_id, col_id, val_num) VALUES (?, ?, ?)");
      T0, T1 : Time;
   begin
      T0 := Clock;
      DB.Execute ("BEGIN");
      for R in 1 .. Rows loop
         for C in 1 .. Cols loop
            if not Is_Missing (R, C, Sparsity_Pct) then
               Stmt.Reset;
               Stmt.Clear_Bindings;
               Stmt.Bind_Int (1, R);
               Stmt.Bind_Int (2, C);
               Ada_Sqlite3.Wide.Bind_Double64 (Stmt, 3, Cell_Value (R, C));
               Stmt.Step;
            end if;
         end loop;
      end loop;
      DB.Execute ("COMMIT");
      T1 := Clock;
      return T1 - T0;
   end Insert_EAV;

   function File_Size_Of (Path : String) return Ada.Directories.File_Size is
   begin
      return Ada.Directories.Size (Path);
   exception
      when others => return 0;
   end File_Size_Of;

   --------------------------------------------------------------------
   --  Sort-key pivot benchmark: three ways to answer "give me every
   --  (record_id, value) pair for column C" for each of a small set of
   --  sort-key columns, against an already-populated, index-free EAV
   --  table. Literal (not bound) col_id values are used in the per-column
   --  SQL text throughout -- deliberately, so the partial-index variant's
   --  WHERE-clause match is unambiguous to the query planner rather than
   --  depending on how SQLite handles a bound parameter against a partial
   --  index's constant predicate.
   --------------------------------------------------------------------

   procedure Scan_Column (DB : Database_Access; Col : Integer; Checksum : in out Long_Float) is
      Stmt : Statement :=
         DB.Prepare ("SELECT record_id, val_num FROM data WHERE col_id = " & Trim_Img (Col));
   begin
      while Stmt.Step = Ada_Sqlite3.ROW loop
         Checksum := Checksum + Ada_Sqlite3.Wide.Column_Double64 (Stmt, 1);
      end loop;
   end Scan_Column;

   --  Approach A: no index at all -- one full table scan per sort-key
   --  column, filtered on col_id. Cost ~ O(K * total_cells).
   function Pivot_No_Index (DB : Database_Access; Sort_Cols : Integer_Array) return Duration is
      T0, T1   : Time;
      Checksum : Long_Float := 0.0;
   begin
      T0 := Clock;
      for C of Sort_Cols loop
         Scan_Column (DB, C, Checksum);
      end loop;
      T1 := Clock;
      Put_Line ("    (no-index checksum " & Checksum'Image & ")");
      return T1 - T0;
   end Pivot_No_Index;

   --  Approach B: build one (col_id, record_id) index over the WHOLE
   --  table right before the sort, use it for all K sort keys, drop it
   --  right after. Unlike the persistent version this ADR's amendment
   --  rejected, this pays the build cost exactly once, in a single bulk
   --  CREATE INDEX (an external sort SQLite can do far more efficiently
   --  than incremental per-row B-tree maintenance), not once per insert.
   function Pivot_Full_Temp_Index (DB : Database_Access; Sort_Cols : Integer_Array) return Duration is
      T0, T1   : Time;
      Checksum : Long_Float := 0.0;
   begin
      T0 := Clock;
      DB.Execute ("CREATE INDEX tmp_full_idx ON data (col_id, record_id)");
      for C of Sort_Cols loop
         Scan_Column (DB, C, Checksum);
      end loop;
      DB.Execute ("DROP INDEX tmp_full_idx");
      T1 := Clock;
      Put_Line ("    (full-temp-index checksum " & Checksum'Image & ")");
      return T1 - T0;
   end Pivot_Full_Temp_Index;

   --  Approach C: a PARTIAL index scoped to only the K sort-key col_ids
   --  (a literal WHERE col_id IN (...) clause), built right before the
   --  sort and dropped right after. Should be cheap to build (proportional
   --  to K/Cols of the table, not the whole table) since it only indexes
   --  the columns actually needed.
   function Pivot_Partial_Temp_Index (DB : Database_Access; Sort_Cols : Integer_Array) return Duration is
      T0, T1   : Time;
      Checksum : Long_Float := 0.0;
      Where_Clause : Unbounded_String := To_Unbounded_String ("col_id IN (");
   begin
      for I in Sort_Cols'Range loop
         if I > Sort_Cols'First then
            Append (Where_Clause, ", ");
         end if;
         Append (Where_Clause, Trim_Img (Sort_Cols (I)));
      end loop;
      Append (Where_Clause, ")");
      T0 := Clock;
      DB.Execute
        ("CREATE INDEX tmp_partial_idx ON data (col_id, record_id) WHERE " &
         To_String (Where_Clause));
      for C of Sort_Cols loop
         Scan_Column (DB, C, Checksum);
      end loop;
      DB.Execute ("DROP INDEX tmp_partial_idx");
      T1 := Clock;
      Put_Line ("    (partial-temp-index checksum " & Checksum'Image & ")");
      return T1 - T0;
   end Pivot_Partial_Temp_Index;

   --------------------------------------------------------------------
   --  Matrix: populate one index-free EAV table per Cols value (dense --
   --  the worst case, most cells to scan/index), then measure all three
   --  pivot approaches at K = 1 and K = 5 sort-key columns against that
   --  same populated table.
   --------------------------------------------------------------------

   Rows : constant Integer := 2000;

   procedure Run_Cols (Cols : Integer) is
      Path : constant String := New_Temp_Path;
      DB   : Database_Access;
      Populate_Time : Duration;
      Bytes : Ada.Directories.File_Size;
   begin
      DB := Open_Bench_DB (Path);
      Build_EAV_Schema (DB);
      Populate_EAV_Cols (DB, Cols);
      Populate_Time := Insert_EAV (DB, Rows, Cols, 0);
      Bytes := File_Size_Of (Path);
      Put_Line
        ("Populated cols=" & Trim_Img (Cols) & " rows=" & Trim_Img (Rows) &
         " in " & Ms_Img (Populate_Time) & " ms (" &
         Trim_Img (Long_Integer (Bytes)) & " bytes)");

      for K of Integer_Array'(1, 5) loop
         declare
            Cols_Chosen : Integer_Array (1 .. K);
            T_No_Idx, T_Full, T_Partial : Duration;
         begin
            for I in 1 .. K loop
               Cols_Chosen (I) := I;
            end loop;
            T_No_Idx  := Pivot_No_Index (DB, Cols_Chosen);
            T_Full    := Pivot_Full_Temp_Index (DB, Cols_Chosen);
            T_Partial := Pivot_Partial_Temp_Index (DB, Cols_Chosen);
            Put_Line
              (Results_File,
               Trim_Img (Cols) & "," & Trim_Img (K) & ",no_index," & Ms_Img (T_No_Idx));
            Put_Line
              (Results_File,
               Trim_Img (Cols) & "," & Trim_Img (K) & ",full_temp_index," & Ms_Img (T_Full));
            Put_Line
              (Results_File,
               Trim_Img (Cols) & "," & Trim_Img (K) & ",partial_temp_index," & Ms_Img (T_Partial));
            Flush (Results_File);
            Put_Line
              ("  cols=" & Trim_Img (Cols) & " K=" & Trim_Img (K) &
               " no_index=" & Ms_Img (T_No_Idx) & "ms full_temp_index=" &
               Ms_Img (T_Full) & "ms partial_temp_index=" & Ms_Img (T_Partial) & "ms");
         end;
      end loop;

      Cleanup (Path);
   end Run_Cols;

begin
   Create (Results_File, Out_File, Results_Path);
   Put_Line (Results_File, "cols,k,approach,time_ms");
   Flush (Results_File);

   for Cols of Integer_Array'(1900, 5000, 10000, 20000) loop
      Run_Cols (Cols);
   end loop;

   Close (Results_File);
   Put_Line ("Done. Results written to " & Results_Path);
end Spill_Schema_Benchmark;
