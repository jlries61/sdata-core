--  BENCHMARK SPIKE -- not a correctness test, not part of run-tests.sh.
--
--  Compares the CURRENT wide-table SQLite disk-spill schema (one SQL column
--  per data column, SData_Core.Backing_Store) against the PROPOSED
--  entity-attribute-value (EAV) schema from ADR-0011
--  (docs/decisions/ADR-0011-eav-disk-spill-schema.md), for the ~2000-column
--  spill ceiling removal tracked as jlries61/sdata#64: insert throughput,
--  fetch throughput, and on-disk size, across column widths spanning well
--  past today's SQLITE_MAX_COLUMN ceiling, and across dense vs sparse
--  (high-missing-fraction) data.
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
with Ada.Exceptions;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada_Sqlite3;             use Ada_Sqlite3;
with Ada_Sqlite3.Wide;

procedure Spill_Schema_Benchmark is

   type Database_Access is access all Ada_Sqlite3.Database;

   --  EAV_No_Index / EAV_Col_Major are a follow-up diagnostic, not part of
   --  ADR-0011's original proposal: added after the initial EAV run showed
   --  insert time blowing up non-linearly (63x for a 2x column-count
   --  increase, 10000->20000 cols) far faster than file size did, to test
   --  whether the culprit is the data_by_col (col_id, record_id) secondary
   --  index being maintained in an order that doesn't match insertion order
   --  (record_id-major) -- every row touches Cols scattered index leaf
   --  pages instead of one contiguous region, thrashing once the working
   --  set exceeds the 64MB page cache.
   type Schema_Kind is (Wide, EAV, EAV_No_Index, EAV_Col_Major);

   type Integer_Array is array (Positive range <>) of Integer;

   Results_Path : constant String := "tests/spill_schema_benchmark_results.csv";
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
      --  few dozen benchmark iterations; reclaimed at process exit.
      GNAT.OS_Lib.Delete_File (Path, Success);
   end Cleanup;

   --------------------------------------------------------------------
   --  Wide-schema (current production) shape
   --------------------------------------------------------------------

   procedure Build_Wide_Schema (DB : Database_Access; Cols : Integer) is
      SQL : Unbounded_String :=
         To_Unbounded_String ("CREATE TABLE data (record_id INTEGER PRIMARY KEY");
   begin
      for C in 1 .. Cols loop
         Append (SQL, ", C" & Trim_Img (C) & " REAL");
      end loop;
      Append (SQL, ")");
      DB.Execute (To_String (SQL));
   end Build_Wide_Schema;

   function Insert_Wide
     (DB : Database_Access; Rows, Cols, Sparsity_Pct : Integer) return Duration
   is
      SQL : Unbounded_String := To_Unbounded_String ("INSERT INTO data (record_id");
      T0, T1 : Time;
   begin
      for C in 1 .. Cols loop
         Append (SQL, ", C" & Trim_Img (C));
      end loop;
      Append (SQL, ") VALUES (?");
      for C in 1 .. Cols loop
         Append (SQL, ", ?");
      end loop;
      Append (SQL, ")");
      declare
         Stmt : Statement := DB.Prepare (To_String (SQL));
      begin
         T0 := Clock;
         DB.Execute ("BEGIN");
         for R in 1 .. Rows loop
            Stmt.Reset;
            Stmt.Clear_Bindings;
            Stmt.Bind_Int (1, R);
            for C in 1 .. Cols loop
               if Is_Missing (R, C, Sparsity_Pct) then
                  Stmt.Bind_Null (C + 1);
               else
                  Ada_Sqlite3.Wide.Bind_Double64 (Stmt, C + 1, Cell_Value (R, C));
               end if;
            end loop;
            Stmt.Step;
         end loop;
         DB.Execute ("COMMIT");
         T1 := Clock;
      end;
      return T1 - T0;
   end Insert_Wide;

   function Fetch_Wide (DB : Database_Access; Rows : Integer) return Duration is
      Stmt : Statement :=
         DB.Prepare ("SELECT * FROM data WHERE record_id BETWEEN 1 AND ? ORDER BY record_id");
      T0, T1   : Time;
      N_Cols   : Natural;
      Checksum : Long_Float := 0.0;
   begin
      Stmt.Bind_Int (1, Rows);
      T0 := Clock;
      while Stmt.Step = Ada_Sqlite3.ROW loop
         N_Cols := Stmt.Column_Count;
         for I in 1 .. N_Cols - 1 loop  --  index 0 is record_id
            if not Stmt.Column_Is_Null (I) then
               Checksum := Checksum + Ada_Sqlite3.Wide.Column_Double64 (Stmt, I);
            end if;
         end loop;
      end loop;
      T1 := Clock;
      Put_Line ("    (wide fetch checksum " & Checksum'Image & ")");
      return T1 - T0;
   end Fetch_Wide;

   --------------------------------------------------------------------
   --  EAV (proposed, ADR-0011) shape
   --------------------------------------------------------------------

   procedure Build_EAV_Schema (DB : Database_Access; With_Index : Boolean := True) is
   begin
      DB.Execute
        ("CREATE TABLE data_cols (col_id INTEGER PRIMARY KEY, " &
         "col_name TEXT UNIQUE NOT NULL)");
      DB.Execute
        ("CREATE TABLE data (record_id INTEGER NOT NULL, col_id INTEGER NOT NULL, " &
         "val_num REAL, val_int INTEGER, val_txt TEXT, " &
         "PRIMARY KEY (record_id, col_id)) WITHOUT ROWID");
      if With_Index then
         DB.Execute ("CREATE INDEX data_by_col ON data (col_id, record_id)");
      end if;
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
     (DB : Database_Access; Rows, Cols, Sparsity_Pct : Integer;
      Col_Major : Boolean := False) return Duration
   is
      Stmt : Statement :=
         DB.Prepare ("INSERT INTO data (record_id, col_id, val_num) VALUES (?, ?, ?)");
      T0, T1 : Time;

      procedure Do_Insert (R, C : Integer) is
      begin
         if not Is_Missing (R, C, Sparsity_Pct) then
            Stmt.Reset;
            Stmt.Clear_Bindings;
            Stmt.Bind_Int (1, R);
            Stmt.Bind_Int (2, C);
            Ada_Sqlite3.Wide.Bind_Double64 (Stmt, 3, Cell_Value (R, C));
            Stmt.Step;
         end if;
      end Do_Insert;
   begin
      T0 := Clock;
      DB.Execute ("BEGIN");
      if Col_Major then
         --  Iterate columns outermost, matching the data_by_col (col_id,
         --  record_id) secondary index's clustering key, so consecutive
         --  inserts land in the same index leaf-page region instead of
         --  scattering across Cols different regions per row.
         for C in 1 .. Cols loop
            for R in 1 .. Rows loop
               Do_Insert (R, C);
            end loop;
         end loop;
      else
         for R in 1 .. Rows loop
            for C in 1 .. Cols loop
               Do_Insert (R, C);
            end loop;
         end loop;
      end if;
      DB.Execute ("COMMIT");
      T1 := Clock;
      return T1 - T0;
   end Insert_EAV;

   function Fetch_EAV (DB : Database_Access; Rows : Integer) return Duration is
      Stmt : Statement :=
         DB.Prepare
           ("SELECT record_id, col_id, val_num FROM data " &
            "WHERE record_id BETWEEN 1 AND ? ORDER BY record_id");
      T0, T1   : Time;
      Checksum : Long_Float := 0.0;
   begin
      Stmt.Bind_Int (1, Rows);
      T0 := Clock;
      while Stmt.Step = Ada_Sqlite3.ROW loop
         Checksum := Checksum + Ada_Sqlite3.Wide.Column_Double64 (Stmt, 2);
      end loop;
      T1 := Clock;
      Put_Line ("    (eav fetch checksum " & Checksum'Image & ")");
      return T1 - T0;
   end Fetch_EAV;

   --------------------------------------------------------------------
   --  Combo runner
   --------------------------------------------------------------------

   function File_Size_Of (Path : String) return Ada.Directories.File_Size is
   begin
      return Ada.Directories.Size (Path);
   exception
      when others => return 0;
   end File_Size_Of;

   procedure Run_Combo (Kind : Schema_Kind; Cols, Rows, Sparsity_Pct : Integer) is
      Path : constant String := New_Temp_Path;
      DB   : Database_Access;
      Insert_Time, Fetch_Time : Duration;
      Bytes : Ada.Directories.File_Size;
   begin
      DB := Open_Bench_DB (Path);
      case Kind is
         when Wide =>
            Build_Wide_Schema (DB, Cols);
            Insert_Time := Insert_Wide (DB, Rows, Cols, Sparsity_Pct);
            Fetch_Time  := Fetch_Wide (DB, Rows);
         when EAV =>
            Build_EAV_Schema (DB);
            Populate_EAV_Cols (DB, Cols);
            Insert_Time := Insert_EAV (DB, Rows, Cols, Sparsity_Pct);
            Fetch_Time  := Fetch_EAV (DB, Rows);
         when EAV_No_Index =>
            Build_EAV_Schema (DB, With_Index => False);
            Populate_EAV_Cols (DB, Cols);
            Insert_Time := Insert_EAV (DB, Rows, Cols, Sparsity_Pct);
            Fetch_Time  := Fetch_EAV (DB, Rows);
         when EAV_Col_Major =>
            Build_EAV_Schema (DB);
            Populate_EAV_Cols (DB, Cols);
            Insert_Time := Insert_EAV (DB, Rows, Cols, Sparsity_Pct, Col_Major => True);
            Fetch_Time  := Fetch_EAV (DB, Rows);
      end case;
      Bytes := File_Size_Of (Path);
      declare
         Line : constant String :=
            Kind'Image & "," & Trim_Img (Cols) & "," & Trim_Img (Rows) & "," &
            Trim_Img (Sparsity_Pct) & "," & Ms_Img (Insert_Time) & "," &
            Ms_Img (Fetch_Time) & "," & Trim_Img (Long_Integer (Bytes));
      begin
         Put_Line (Line);
         Put_Line (Results_File, Line);
         Flush (Results_File);
      end;
      Cleanup (Path);
   exception
      when E : others =>
         Put_Line
           ("SKIPPED " & Kind'Image & " cols=" & Trim_Img (Cols) &
            " rows=" & Trim_Img (Rows) & " sparsity=" & Trim_Img (Sparsity_Pct) &
            ": " & Ada.Exceptions.Exception_Message (E));
         Put_Line
           (Results_File,
            Kind'Image & "," & Trim_Img (Cols) & "," & Trim_Img (Rows) & "," &
            Trim_Img (Sparsity_Pct) & ",SKIPPED,SKIPPED,SKIPPED");
         Flush (Results_File);
         Cleanup (Path);
   end Run_Combo;

   --------------------------------------------------------------------
   --  Combo matrix.  Rows held constant at 2000 (a plausible spill-segment
   --  size); Cols sweeps from narrow to well past today's ~2000-column
   --  SQLite ceiling (Wide is only run up to 1900 -- it cannot go further);
   --  Sparsity_Pct is the percentage of cells that are missing.
   --------------------------------------------------------------------

   Rows : constant Integer := 2000;

   --  FOLLOW-UP RUN (2026-07-29): the first full matrix (see
   --  tests/spill_schema_benchmark_results.csv) found EAV insert time
   --  blowing up 63x from 10000->20000 columns while file size only grew
   --  ~2x -- a cliff, not a smooth regression. This second pass isolates
   --  whether the data_by_col (col_id, record_id) secondary index is the
   --  cause, at just the two sizes that showed the cliff (dense only, to
   --  keep this pass fast). Written to a separate results file so the
   --  original full-matrix data stays intact for comparison.

begin
   Create (Results_File, Out_File, "tests/spill_schema_benchmark_followup.csv");
   Put_Line (Results_File, "schema,cols,rows,sparsity_pct,insert_ms,fetch_ms,file_bytes");
   Flush (Results_File);
   Put_Line ("schema,cols,rows,sparsity_pct,insert_ms,fetch_ms,file_bytes");

   for Cols of Integer_Array'(10000, 20000) loop
      Run_Combo (EAV_No_Index, Cols, Rows, 0);
      Run_Combo (EAV_Col_Major, Cols, Rows, 0);
   end loop;

   Close (Results_File);
   Put_Line ("Done. Results written to tests/spill_schema_benchmark_followup.csv");
end Spill_Schema_Benchmark;
