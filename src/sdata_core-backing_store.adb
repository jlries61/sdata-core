--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Containers.Vectors;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada_Sqlite3.Wide;
with SData_Core.Config;
use type SData_Core.Config.Spill_Schema_Kind;
with SData_Core.Signals;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Backing_Store is

   --  Organisation: the trivial state accessors (Is_Active / Is_EAV / Col_Id
   --  / Path) and the segment-cache reset (Clear_Cache) come first; then the
   --  lifecycle (Open creates the temp DB on demand and latches the active
   --  schema, Close / Finalize tear it down); then the col_id-registry
   --  helpers shared by the EAV Spill/Fetch/Commit_Output_Rename bodies;
   --  then the two heavy operations, Spill (memory -> disk) and Fetch (disk
   --  -> memory, one segment at a time), each of which dispatches to a
   --  Wide- or EAV-shaped private body; then the Commit_Output_Table
   --  helpers.  Spill's atomicity / clean-abort contract is documented in
   --  the spec; the comments here cover only the mechanics.

   --  Quote Name as a SQLite identifier: wrap it in [ ] and escape any embedded
   --  ']' by doubling it (the sole metacharacter inside a bracket-quoted
   --  identifier).  This lets column names hold spaces, punctuation, or SQL
   --  keywords without parse errors or injection.  Buf is sized Name'Length * 2
   --  for the worst case where every character is a ']'.
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

   --  Trivial identity-ish hash for a col_id key (Fetch_EAV's local
   --  reverse-lookup map); col_ids are small sequential Naturals, not
   --  attacker-controlled input, so no distribution concerns apply.
   function Hash_Natural (N : Natural) return Ada.Containers.Hash_Type is
     (Ada.Containers.Hash_Type (N));

   function Is_Active (Self : Backing_Store) return Boolean is
   begin
      return Self.Is_Active;
   end Is_Active;

   function Is_EAV (Self : Backing_Store) return Boolean is
   begin
      return Self.Schema = SData_Core.Config.Spill_EAV;
   end Is_EAV;

   --  Name is always exactly "data" or "output_data" (Table.adb never
   --  calls Spill/Fetch/Commit_Output_Rename with anything else), so a
   --  plain equality branch selects the right registry -- looked up
   --  directly against the field (no map copy: Col_Id_Maps.Map is a hashed
   --  map, and copying it just to run one Find would be an O(column-count)
   --  cost paid on every single Col_Id call, which Fetch_EAV calls once per
   --  column per segment materialize).
   function Col_Id (Self : Backing_Store; Name, Column_Name : String) return Natural is
      Cur : Col_Id_Maps.Cursor;
   begin
      if Name = "data" then
         Cur := Self.Data_Col_Ids.Find (Column_Name);
      else
         Cur := Self.Output_Col_Ids.Find (Column_Name);
      end if;
      if Col_Id_Maps.Has_Element (Cur) then
         return Col_Id_Maps.Element (Cur);
      else
         return 0;
      end if;
   end Col_Id;

   function Path (Self : Backing_Store) return String is
   begin
      if Self.Is_Active then
         return To_String (Self.Temp_Path);
      else
         return "";
      end if;
   end Path;

   procedure Clear_Cache (Self : in out Backing_Store) is
   begin
      Self.Seg_Cache.Clear;
      Self.Seg_Start := 0;
      Self.Seg_End   := 0;
   end Clear_Cache;

   procedure Execute (Self : in out Backing_Store; SQL : String) is
   begin
      Self.DB.Execute (SQL);
   end Execute;

   procedure Commit_Output_Rename (Self : in out Backing_Store) is
   begin
      Self.Data_Col_Ids   := Self.Output_Col_Ids;
      Self.Data_Next_Id   := Self.Output_Next_Id;
      Self.Output_Col_Ids.Clear;
      Self.Output_Next_Id := 1;
   end Commit_Output_Rename;

   procedure Reset_Col_Ids (Self : in out Backing_Store) is
   begin
      Self.Data_Col_Ids.Clear;
      Self.Data_Next_Id := 1;
      Self.Output_Col_Ids.Clear;
      Self.Output_Next_Id := 1;
   end Reset_Col_Ids;

   procedure Open (Self : in out Backing_Store) is
      FD : GNAT.OS_Lib.File_Descriptor;
      Temp_Name : GNAT.Strings.String_Access;
   begin
      if Self.Is_Active then return; end if;

      --  Latch the active schema for this store's whole lifetime.  The
      --  SDATA_SPILL_SCHEMA environment variable is an undocumented
      --  override of SData_Core.Config.Spill_Schema, for fast rollback
      --  during the EAV rollout window (ADR-0011's Feature Flag Plan) --
      --  not a public OPTIONS key.  Any other value (including unset)
      --  falls back to the compiled-in Config default.
      Self.Schema := SData_Core.Config.Spill_Schema;
      if Ada.Environment_Variables.Exists ("SDATA_SPILL_SCHEMA") then
         declare
            Override : constant String := Ada.Characters.Handling.To_Upper
               (Ada.Environment_Variables.Value ("SDATA_SPILL_SCHEMA"));
         begin
            if Override = "WIDE" then
               Self.Schema := SData_Core.Config.Spill_Wide;
            elsif Override = "EAV" then
               Self.Schema := SData_Core.Config.Spill_EAV;
            end if;
         end;
      end if;

      GNAT.OS_Lib.Create_Temp_File (FD, Temp_Name);
      GNAT.OS_Lib.Close (FD);
      Self.Temp_Path := To_Unbounded_String (Temp_Name.all);
      Self.DB := new Ada_Sqlite3.Database'(Ada_Sqlite3.Open (Temp_Name.all));
      --  This is a process-private temp file; we need no durability at all.
      --  Disable the journal and fsync entirely, and give SQLite a large page
      --  cache so that external-merge sort runs stay hot across passes.
      --  temp_store=MEMORY keeps SQLite's own sort intermediates in RAM.
      Self.DB.Execute ("PRAGMA journal_mode = OFF");
      Self.DB.Execute ("PRAGMA synchronous = OFF");
      Self.DB.Execute ("PRAGMA cache_size = -65536");  --  64 MB (negative = KiB)
      Self.DB.Execute ("PRAGMA temp_store = MEMORY");
      Self.Is_Active := True;
      SData_Core.Signals.Register_Cleanup_Path (Temp_Name.all);
      GNAT.Strings.Free (Temp_Name);
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not create disk backing store for dataset"
            & " [temp_path=" & To_String (Self.Temp_Path) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Open;

   procedure Close (Self : in out Backing_Store) is
      Success : Boolean;
   begin
      if not Self.Is_Active then return; end if;
      --  Mark inactive first so a second call (explicit + automatic) is a no-op.
      Self.Is_Active := False;
      SData_Core.Signals.Clear_Cleanup_Path;
      declare
         Path : constant String := To_String (Self.Temp_Path);
      begin
         --  We avoid manually freeing Self.DB here: doing so triggers a
         --  double-finalization crash inside Ada_Sqlite3 (observed with
         --  ada_sqlite3 0.1.1 -- the only published version; upstream
         --  github.com/gtnoble/ada-sqlite3 @ 2edbceb).  No upstream issue
         --  is filed as of 2026-06-02 and no fixed release exists.  The OS
         --  reclaims the memory; we only need to remove the file.  REVISIT
         --  when bumping ada_sqlite3 past 0.1.1 (see alire.toml): re-test
         --  whether freeing Self.DB is safe and, if so, drop this leak.
         GNAT.OS_Lib.Delete_File (Path, Success);
      end;
      Self.Seg_Cache.Clear;
      Self.Seg_Start := 0;
      Self.Seg_End   := 0;
      Self.Reset_Col_Ids;
   end Close;

   overriding procedure Finalize (Self : in out Backing_Store) is
   begin
      Close (Self);
   end Finalize;

   ----------------------------------------------------------------
   --  EAV col_id resolution: stable across every Spill call for the whole
   --  session (not just within one call), because Add_Row spills a table's
   --  growing segment incrementally as it fills, not once -- a column's
   --  col_id must not change (or be re-derived) between segment 1's spill
   --  and segment 2's, or Fetch would silently read the wrong column's data
   --  back for rows written under a stale/duplicate id.  Resolving purely
   --  from the in-memory Map (never re-querying <name>_cols) is what makes
   --  this correct: the map is the single source of truth for a session,
   --  written through to the SQL registry table only when a name is
   --  genuinely new to it.
   ----------------------------------------------------------------
   function Resolve_Col_Id
     (DB : Database_Access; Map : in out Col_Id_Maps.Map; Next_Id : in out Positive;
      Name, Column_Name : String) return Positive
   is
      Cur : constant Col_Id_Maps.Cursor := Map.Find (Column_Name);
   begin
      if Col_Id_Maps.Has_Element (Cur) then
         return Col_Id_Maps.Element (Cur);
      end if;
      declare
         New_Id : constant Positive := Next_Id;
         Stmt   : Ada_Sqlite3.Statement :=
            DB.Prepare ("INSERT INTO " & Sql_Id (Name & "_cols") &
                        " (col_id, col_name) VALUES (?, ?)");
      begin
         Stmt.Bind_Int (1, New_Id);
         Stmt.Bind_Text (2, Column_Name);
         Stmt.Step;
         Map.Insert (Column_Name, New_Id);
         Next_Id := Next_Id + 1;
         return New_Id;
      end;
   end Resolve_Col_Id;

   procedure Ensure_EAV_Schema (DB : Database_Access; Name : String) is
   begin
      DB.Execute
        ("CREATE TABLE IF NOT EXISTS " & Sql_Id (Name & "_cols") &
         " (col_id INTEGER PRIMARY KEY, col_name TEXT UNIQUE NOT NULL)");
      DB.Execute
        ("CREATE TABLE IF NOT EXISTS " & Sql_Id (Name) &
         " (record_id INTEGER NOT NULL, col_id INTEGER NOT NULL, " &
         "val_num REAL, val_int INTEGER, val_txt TEXT, " &
         "PRIMARY KEY (record_id, col_id)) WITHOUT ROWID");
   end Ensure_EAV_Schema;

   ----------------------------------------------------------------
   --  Spill: dispatches to the Wide (legacy, one SQL column per data
   --  column) or EAV (ADR-0011) body per the store's latched schema.
   ----------------------------------------------------------------

   procedure Spill_Wide (Self  : in out Backing_Store;
                         T     : in out Columns.Column_Maps.Map;
                         Name  : String;
                         Start : Positive) is
      SQL : Unbounded_String;
      Memory_Rows : Natural := 0;
      package Name_Vecs is new Ada.Containers.Vectors (Positive, Unbounded_String);
      package Cursor_Vecs is new Ada.Containers.Vectors
        (Positive, Columns.Column_Maps.Cursor, Columns.Column_Maps."=");
      Col_Names   : Name_Vecs.Vector;
      Col_Cursors : Cursor_Vecs.Vector;
   begin
      --  Snapshot the column names (upper-cased, for the SQL identifiers) and
      --  their cursors once, in a single stable order reused by both the CREATE
      --  and the INSERT below.  Memory_Rows is the segment height: every column
      --  vector has the same length, so the first non-empty one suffices.
      for Pos in T.Iterate loop
         Col_Names.Append
           (To_Unbounded_String (Columns.Image (Columns.Column_Maps.Key (Pos))));
         Col_Cursors.Append (Pos);
         if Memory_Rows = 0 then
            Memory_Rows := Natural
              (Columns.Column_Maps.Constant_Reference (T, Pos).Element.all.Data.Length);
         end if;
      end loop;
      if Memory_Rows = 0 then return; end if;

      --  Build "CREATE TABLE IF NOT EXISTS [Name] (record_id INTEGER PRIMARY
      --  KEY, <col> <affinity>, ...)".  record_id is the global logical row
      --  number (set in the INSERT below), so Fetch can reload any segment by
      --  record_id range.  Each column's Ada type maps to the SQLite affinity
      --  Numeric -> REAL, Integer -> INTEGER, String -> TEXT.
      SQL := To_Unbounded_String
        ("CREATE TABLE IF NOT EXISTS [" & Name & "] (record_id INTEGER PRIMARY KEY");
      for C in 1 .. Natural (Col_Names.Length) loop
         declare
            Ref   : constant Columns.Column_Maps.Constant_Reference_Type :=
               Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
            SQL_T : constant String := (if Ref.Element.all.Typ = Col_Numeric then "REAL"
                                        elsif Ref.Element.all.Typ = Col_Integer then "INTEGER"
                                        else "TEXT");
         begin
            Append (SQL, ", " & Sql_Id (To_String (Col_Names.Element (C))) & " " & SQL_T);
         end;
      end loop;
      Append (SQL, ")");
      Self.DB.Execute (To_String (SQL));

      --  Build the parameterised "INSERT OR REPLACE INTO [Name] (record_id,
      --  <cols>) VALUES (?, ?, ...)" prepared once and reused for every row.
      --  OR REPLACE so re-spilling an overlapping record_id range overwrites
      --  cleanly rather than colliding on the primary key.
      SQL := To_Unbounded_String
        ("INSERT OR REPLACE INTO [" & Name & "] (record_id");
      for N of Col_Names loop Append (SQL, ", " & Sql_Id (To_String (N))); end loop;
      Append (SQL, ") VALUES (?");
      for I in 1 .. Natural (Col_Names.Length) loop Append (SQL, ", ?"); end loop;
      Append (SQL, ")");

      declare
         Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare (To_String (SQL));
      begin
         --  Batch all inserts in one transaction; without this, SQLite
         --  auto-commits each row individually, causing O(N) lock cycles.
         Self.DB.Execute ("BEGIN");
         for R in 1 .. Memory_Rows loop
            Stmt.Reset;
            Stmt.Clear_Bindings;
            --  record_id = global logical row: this segment's first row (Start)
            --  plus the in-segment offset (R - 1).
            Stmt.Bind_Int (1, Start + R - 1);
            for C in 1 .. Natural (Col_Names.Length) loop
               declare
                  Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
                     Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
                  Val : constant Value := Ref.Element.all.Data.Element (R);
               begin
                  case Val.Kind is
                     --  Bind via the 64-bit path (Ada_Sqlite3.Wide) rather
                     --  than the high-level Bind_Double, which narrows to 32-bit
                     --  Float in ada_sqlite3 0.1.1 -- spilled numerics must keep
                     --  the same double precision as the in-memory table (#54).
                     when Val_Numeric =>
                        Ada_Sqlite3.Wide.Bind_Double64
                          (Stmt, C + 1, Long_Float (Val.Num_Val));
                     when Val_Integer =>
                        Ada_Sqlite3.Wide.Bind_Int64
                          (Stmt, C + 1, Long_Long_Integer (Val.Int_Val));
                     when Val_String  => Stmt.Bind_Text (C + 1, To_String (Val.Str_Val));
                     when Val_Missing => Stmt.Bind_Null (C + 1);
                  end case;
               end;
            end loop;
            Stmt.Step;
         end loop;
         Self.DB.Execute ("COMMIT");
      end;

      --  SUCCESS path only: the rows are now durably in the DB, so release the
      --  in-memory vectors (the caller then advances its segment start past
      --  them).  On SQLite_Error this line is never reached -- per the spec's
      --  clean-abort contract, memory must stay the sole copy of the data.
      for Pos in T.Iterate loop T.Reference (Pos).Element.all.Data.Clear; end loop;
   exception
      when E : SQLite_Error =>
         declare
            Msg : constant String := Ada.Exceptions.Exception_Message (E);
            Upper_Msg : constant String :=
               Ada.Characters.Handling.To_Upper (Msg);
         begin
            if Ada.Strings.Fixed.Index (Upper_Msg, "TOO MANY COLUMNS") > 0
            then
               --  SQLite hard cap (~2000 columns per table).  Report the
               --  column count and advise -m 0 to keep the table in memory.
               --  Keep the message under GNAT's 200-char exception-message
               --  limit: "dataset ""data"" has ... [SQLite: ...]" ~ 150 chars.
               raise Script_Error with
                  "dataset """ & Name & """ has too many columns for"
                  & " SQLite spill ("
                  & Columns.Img (Natural (Col_Names.Length))
                  & " cols, limit ~2000); use -m 0 or fewer columns"
                  & " [SQLite: " & Msg & "]";
            else
               raise Script_Error with
                  "could not write dataset to disk (disk full?)"
                  & " [table=" & Name
                  & ", rows=" & Columns.Img (Memory_Rows)
                  & ", segment_start=" & Columns.Img (Start) & "]: "
                  & Msg;
            end if;
         end;
   end Spill_Wide;

   procedure Spill_EAV (Self  : in out Backing_Store;
                        T     : in out Columns.Column_Maps.Map;
                        Name  : String;
                        Start : Positive) is
      Memory_Rows : Natural := 0;
      package Name_Vecs is new Ada.Containers.Vectors (Positive, Unbounded_String);
      package Cursor_Vecs is new Ada.Containers.Vectors
        (Positive, Columns.Column_Maps.Cursor, Columns.Column_Maps."=");
      package Id_Vecs is new Ada.Containers.Vectors (Positive, Positive);
      Col_Names   : Name_Vecs.Vector;
      Col_Cursors : Cursor_Vecs.Vector;
      Col_Ids     : Id_Vecs.Vector;
      Is_Data     : constant Boolean := (Name = "data");
   begin
      for Pos in T.Iterate loop
         Col_Names.Append
           (To_Unbounded_String (Columns.Image (Columns.Column_Maps.Key (Pos))));
         Col_Cursors.Append (Pos);
         if Memory_Rows = 0 then
            Memory_Rows := Natural
              (Columns.Column_Maps.Constant_Reference (T, Pos).Element.all.Data.Length);
         end if;
      end loop;
      if Memory_Rows = 0 then return; end if;

      Ensure_EAV_Schema (Self.DB, Name);

      declare
         --  OR REPLACE, matching Spill_Wide: re-spilling an overlapping
         --  record_id range (Sorting.Sort flushes whatever's still resident
         --  in memory before its rebuild, which can overlap a range already
         --  on disk) must overwrite cleanly rather than collide on the
         --  (record_id, col_id) primary key.
         --  REVIEW: this only replaces cells that are still non-missing on
         --  re-spill. Spill_Wide's OR REPLACE rewrites an entire row
         --  (including NULLing out a cell that became missing since the
         --  first spill); a sparse re-spill here would leave a stale
         --  non-missing row behind for a cell that flipped to missing
         --  in between. Not exercised by any current caller (every re-spill
         --  observed re-writes unchanged data), but worth a guard or a
         --  DELETE-then-INSERT if a future caller ever re-spills mutated
         --  data.
         Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare
            ("INSERT OR REPLACE INTO " & Sql_Id (Name) &
             " (record_id, col_id, val_num, val_int, val_txt) VALUES (?, ?, ?, ?, ?)");
      begin
         --  One transaction for both the (rare -- only genuinely new column
         --  names) col_id registrations and every value insert: if a disk
         --  error strikes mid-Spill, the clean-abort contract (see the spec)
         --  must hold for the registry too, not just the value rows -- a
         --  half-registered column with no corresponding data would be a
         --  worse state than the pre-call one.
         Self.DB.Execute ("BEGIN");

         if Is_Data then
            for C in 1 .. Natural (Col_Names.Length) loop
               Col_Ids.Append
                 (Resolve_Col_Id
                    (Self.DB, Self.Data_Col_Ids, Self.Data_Next_Id, Name,
                     To_String (Col_Names.Element (C))));
            end loop;
         else
            for C in 1 .. Natural (Col_Names.Length) loop
               Col_Ids.Append
                 (Resolve_Col_Id
                    (Self.DB, Self.Output_Col_Ids, Self.Output_Next_Id, Name,
                     To_String (Col_Names.Element (C))));
            end loop;
         end if;

         for R in 1 .. Memory_Rows loop
            for C in 1 .. Natural (Col_Names.Length) loop
               declare
                  Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
                     Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
                  Val : constant Value := Ref.Element.all.Data.Element (R);
               begin
                  --  Missing is sparse: no row at all, not a stored NULL
                  --  across an always-present wide row (ADR-0011).
                  if Val.Kind /= Val_Missing then
                     Stmt.Reset;
                     Stmt.Clear_Bindings;
                     Stmt.Bind_Int (1, Start + R - 1);
                     Stmt.Bind_Int (2, Col_Ids.Element (C));
                     case Val.Kind is
                        when Val_Numeric =>
                           Ada_Sqlite3.Wide.Bind_Double64 (Stmt, 3, Long_Float (Val.Num_Val));
                        when Val_Integer =>
                           Ada_Sqlite3.Wide.Bind_Int64 (Stmt, 4, Long_Long_Integer (Val.Int_Val));
                        when Val_String  =>
                           Stmt.Bind_Text (5, To_String (Val.Str_Val));
                        when Val_Missing => null;  --  unreachable, guarded above
                     end case;
                     Stmt.Step;
                  end if;
               end;
            end loop;
         end loop;

         Self.DB.Execute ("COMMIT");
      end;

      --  SUCCESS path only -- see Spill_Wide's identical comment.
      for Pos in T.Iterate loop T.Reference (Pos).Element.all.Data.Clear; end loop;
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not write dataset to disk (disk full?)"
            & " [table=" & Name
            & ", rows=" & Columns.Img (Memory_Rows)
            & ", segment_start=" & Columns.Img (Start) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Spill_EAV;

   procedure Spill (Self  : in out Backing_Store;
                    T     : in out Columns.Column_Maps.Map;
                    Name  : String;
                    Start : Positive) is
   begin
      if T.Is_Empty then return; end if;

      --  We are about to mutate T (clearing its in-memory vectors on success),
      --  so any prefetch cache built from it would go stale -- drop it now.
      Clear_Cache (Self);

      --  Create the temp DB lazily on the first spill (idempotent thereafter),
      --  latching the active schema.
      Open (Self);

      if Self.Is_EAV then
         Spill_EAV (Self, T, Name, Start);
      else
         Spill_Wide (Self, T, Name, Start);
      end if;
   end Spill;

   ----------------------------------------------------------------
   --  Fetch: dispatches to the Wide or EAV body per the latched schema.
   --  Both always read from the [data] table -- Fetch is never called for
   --  "output_data" (write-only until Commit_Output_Table's rename makes it
   --  "data"), matching the original implementation.
   ----------------------------------------------------------------

   function Fetch_Wide (Self      : in out Backing_Store;
                        Row       : Positive;
                        Col       : String;
                        T         : Columns.Column_Maps.Map;
                        Row_Count : Natural) return SData_Core.Values.Value is
      U_Col : constant String := Ada.Characters.Handling.To_Upper (Col);
   begin
      --  Cache miss -> load the segment containing Row.  Seg_Start = 0 means
      --  the cache is empty; otherwise [Seg_Start, Seg_End] is what we hold.
      --  The cache holds exactly ONE segment (no LRU), so a scan that jumps
      --  between segments re-queries each time -- see the Add_Row cost note.
      if Self.Seg_Start = 0 or else Row < Self.Seg_Start or else Row > Self.Seg_End then
         declare
            --  Limit = rows per segment = the same cells/columns budget Add_Row
            --  spills at, so disk segments line up with the in-memory ones.
            --  Segments tile the row space into Limit-sized blocks: block S_Idx
            --  (0-based) covers rows [S_Start, S_End], with S_End clamped to the
            --  table height (Row_Count).  Row is guaranteed to fall in it.
            Col_Count : constant Positive := Positive'Max (1, Natural (T.Length));
            Limit   : constant Positive :=
               (if SData_Core.Config.Max_Table_Cells > 0
                then Positive'Max (1, SData_Core.Config.Max_Table_Cells / Col_Count)
                else 1);
            S_Idx   : constant Natural  := (Row - 1) / Limit;
            S_Start : constant Positive := S_Idx * Limit + 1;
            S_End   : constant Positive :=
               Positive'Min (S_Start + Limit - 1, Row_Count);
            Num_Rows : constant Natural := S_End - S_Start + 1;
            Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare
               ("SELECT * FROM [data] WHERE record_id >= ? AND record_id <= ?" &
                " ORDER BY record_id");
            Num_Cols : Integer;
         begin
            Stmt.Bind_Int (1, S_Start);
            Stmt.Bind_Int (2, S_End);
            Self.Seg_Cache.Clear;

            --  Column count is known from the prepared statement before stepping.
            Num_Cols := Stmt.Column_Count - 1;  --  exclude record_id at index 0

            --  Pre-insert an empty vector for each data column and reserve
            --  capacity so that subsequent Appends do not reallocate.
            for I in 1 .. Num_Cols loop
               declare
                  CName : constant String := Stmt.Column_Name (I);
                  Empty : constant Columns.Value_Vectors.Vector :=
                     Columns.Value_Vectors.Empty_Vector;
               begin
                  Self.Seg_Cache.Include (CName, Empty);
                  Self.Seg_Cache.Reference (CName).Reserve_Capacity
                     (Ada.Containers.Count_Type (Num_Rows));
               end;
            end loop;

            --  Fetch all rows in one sequential scan.
            while Stmt.Step = Ada_Sqlite3.ROW loop
               for I in 1 .. Num_Cols loop
                  declare
                     CName : constant String := Stmt.Column_Name (I);
                     Typ   : constant Ada_Sqlite3.Column_Type := Stmt.Get_Column_Type (I);
                     Val   : Value;
                  begin
                     if Stmt.Column_Is_Null (I) then
                        Val := (Kind => Val_Missing);
                     elsif Typ = Ada_Sqlite3.Float_Type then
                        Val := (Kind => Val_Numeric,
                                Num_Val => Real
                                  (Ada_Sqlite3.Wide.Column_Double64 (Stmt, I)));
                     elsif Typ = Ada_Sqlite3.Integer_Type then
                        Val := (Kind => Val_Integer, Int_Val => Int
                                  (Ada_Sqlite3.Wide.Column_Int64 (Stmt, I)));
                     else
                        Val := (Kind    => Val_String,
                                Str_Val => To_Unbounded_String (Stmt.Column_Text (I)));
                     end if;
                     Self.Seg_Cache.Reference (CName).Append (Val);
                  end;
               end loop;
            end loop;

            Self.Seg_Start := S_Start;
            Self.Seg_End   := S_End;
         end;
      end if;

      --  Return the cached value.  Idx is Row's 1-based position within the
      --  cached segment.  A column absent from the cache, or a short column,
      --  yields Missing rather than raising.
      if Self.Seg_Cache.Contains (U_Col) then
         declare
            Idx : constant Positive := Row - Self.Seg_Start + 1;
            Ref : constant Seg_Data_Maps.Constant_Reference_Type :=
               Self.Seg_Cache.Constant_Reference (U_Col);
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
            & " [row=" & Columns.Img (Row)
            & ", column=" & U_Col & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Fetch_Wide;

   function Fetch_EAV (Self      : in out Backing_Store;
                       Row       : Positive;
                       Col       : String;
                       T         : Columns.Column_Maps.Map;
                       Row_Count : Natural) return SData_Core.Values.Value is
      U_Col : constant String := Ada.Characters.Handling.To_Upper (Col);
   begin
      if Self.Seg_Start = 0 or else Row < Self.Seg_Start or else Row > Self.Seg_End then
         declare
            Col_Count : constant Positive := Positive'Max (1, Natural (T.Length));
            Limit   : constant Positive :=
               (if SData_Core.Config.Max_Table_Cells > 0
                then Positive'Max (1, SData_Core.Config.Max_Table_Cells / Col_Count)
                else 1);
            S_Idx   : constant Natural  := (Row - 1) / Limit;
            S_Start : constant Positive := S_Idx * Limit + 1;
            S_End   : constant Positive :=
               Positive'Min (S_Start + Limit - 1, Row_Count);
            Num_Rows : constant Natural := S_End - S_Start + 1;

            --  col_id -> column-name reverse lookup, scoped to T's current
            --  columns only.  A column already dropped/renamed out of T is
            --  simply unresolvable here and its spilled rows are skipped --
            --  the same pre-existing, out-of-scope Rename_Column/Drop_Column
            --  gap the Wide schema has too (ADR-0011).  Rebuilt every
            --  segment-materializing call; bounded by column count, not row
            --  count.
            package Id_Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
              (Key_Type => Natural, Element_Type => String,
               Hash => Hash_Natural, Equivalent_Keys => "=");
            Id_To_Name : Id_Name_Maps.Map;

            Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare
               ("SELECT record_id, col_id, val_num, val_int, val_txt FROM [data] " &
                "WHERE record_id >= ? AND record_id <= ? ORDER BY record_id");
         begin
            Self.Seg_Cache.Clear;

            --  Pre-fill every column T currently knows about with Val_Missing
            --  for the whole segment -- a sparse EAV row's absence IS
            --  Missing, so there is no query result to overwrite with for a
            --  missing cell; see ADR-0011.
            for Pos in T.Iterate loop
               declare
                  C_Name : constant String := Columns.Image (Columns.Column_Maps.Key (Pos));
                  U_Name : constant String := Ada.Characters.Handling.To_Upper (C_Name);
                  Id     : constant Natural := Self.Col_Id ("data", C_Name);
                  Filled : Columns.Value_Vectors.Vector;
               begin
                  if Id > 0 then
                     Id_To_Name.Include (Id, U_Name);
                  end if;
                  Filled.Reserve_Capacity (Ada.Containers.Count_Type (Num_Rows));
                  for I in 1 .. Num_Rows loop
                     Filled.Append ((Kind => Val_Missing));
                  end loop;
                  Self.Seg_Cache.Include (U_Name, Filled);
               end;
            end loop;

            Stmt.Bind_Int (1, S_Start);
            Stmt.Bind_Int (2, S_End);
            while Stmt.Step = Ada_Sqlite3.ROW loop
               declare
                  Rec_Id : constant Positive := Positive (Stmt.Column_Int (0));
                  Cid    : constant Natural  := Natural (Stmt.Column_Int (1));
               begin
                  if Id_To_Name.Contains (Cid) then
                     declare
                        U_Name : constant String := Id_To_Name.Element (Cid);
                        Idx    : constant Positive := Rec_Id - S_Start + 1;
                        Val    : Value;
                     begin
                        if not Stmt.Column_Is_Null (2) then
                           Val := (Kind => Val_Numeric,
                                   Num_Val => Real (Ada_Sqlite3.Wide.Column_Double64 (Stmt, 2)));
                        elsif not Stmt.Column_Is_Null (3) then
                           Val := (Kind => Val_Integer,
                                   Int_Val => Int (Ada_Sqlite3.Wide.Column_Int64 (Stmt, 3)));
                        elsif not Stmt.Column_Is_Null (4) then
                           Val := (Kind => Val_String,
                                   Str_Val => To_Unbounded_String (Stmt.Column_Text (4)));
                        else
                           --  Unreachable in practice: Spill_EAV never
                           --  inserts a row unless at least one value column
                           --  is non-null.
                           Val := (Kind => Val_Missing);
                        end if;
                        Self.Seg_Cache.Reference (U_Name).Replace_Element (Idx, Val);
                     end;
                  end if;
               end;
            end loop;

            Self.Seg_Start := S_Start;
            Self.Seg_End   := S_End;
         end;
      end if;

      if Self.Seg_Cache.Contains (U_Col) then
         declare
            Idx : constant Positive := Row - Self.Seg_Start + 1;
            Ref : constant Seg_Data_Maps.Constant_Reference_Type :=
               Self.Seg_Cache.Constant_Reference (U_Col);
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
            & " [row=" & Columns.Img (Row)
            & ", column=" & U_Col & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Fetch_EAV;

   function Fetch (Self      : in out Backing_Store;
                   Row       : Positive;
                   Col       : String;
                   T         : Columns.Column_Maps.Map;
                   Row_Count : Natural) return SData_Core.Values.Value is
   begin
      if Self.Is_EAV then
         return Fetch_EAV (Self, Row, Col, T, Row_Count);
      else
         return Fetch_Wide (Self, Row, Col, T, Row_Count);
      end if;
   end Fetch;

end SData_Core.Backing_Store;
