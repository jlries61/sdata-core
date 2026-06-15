--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Backing_Store owns the SQLite disk-spill kernel: the DB handle,
--  the temp file, the input-segment prefetch cache, and segment bounds.  It is
--  parameterized on Columns.Column_Maps.Map -- it does NOT with SData_Core.Table,
--  so it cannot see Table's globals; the encapsulation is compiler-enforced
--  (ADR-0007).  A single instance is correct: one temp DB holds both the
--  "data" and "output_data" tables, and the read cache is input-only.

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Finalization;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada_Sqlite3;
with SData_Core.Columns;
with SData_Core.Values;

package SData_Core.Backing_Store is

   type Backing_Store is tagged limited private;

   --  Create the temp DB and register it for signal cleanup.  Idempotent:
   --  no-op if already active.  Named Open rather than Initialize because a
   --  primitive named Initialize with this profile would OVERRIDE
   --  Limited_Controlled.Initialize and auto-run at object creation -- which
   --  would eagerly create the singleton's temp DB at elaboration, changing
   --  the on-demand behavior of the original Initialize_Backing_Store.
   procedure Open (Self : in out Backing_Store);

   function Is_Active (Self : Backing_Store) return Boolean;

   --  The backing-store temp file path, or "" if inactive (signal cleanup).
   function Path (Self : Backing_Store) return String;

   --  Write every in-memory row of T to the [Name] SQLite table in one
   --  transaction, then clear the in-memory column vectors.  Name is
   --  "data" | "output_data".  Start is the segment's first logical row.
   --
   --  Atomicity / failure contract -- all-or-nothing with a deliberate
   --  CLEAN-ABORT guarantee:
   --
   --    * Success: rows committed, then the in-memory Data vectors are
   --      cleared and the caller advances its segment start past the
   --      spilled segment.
   --
   --    * SQLite_Error (e.g. disk full) anywhere in BEGIN..COMMIT: SQLite
   --      rolls back, nothing reaches disk; the in-memory Clear is SKIPPED,
   --      so memory still holds every row; and the caller unwinds before
   --      touching its segment start or row count.  Net result is the exact
   --      pre-call state -- the table stays fully readable from memory --
   --      surfaced as Script_Error.
   --
   --  WARNING: do NOT force the in-memory Clear onto the exception path.
   --  Binding only READS the Value vectors; on failure they are the sole
   --  surviving copy.  Clearing them after a failed write would discard live
   --  rows -- turning a recoverable disk-full into data loss.
   --
   --  A failed FIRST spill leaves Is_Active = True (set by Open before
   --  the write).  Benign and intentionally NOT unwound: reads still hit the
   --  in-memory segment, Open is idempotent so no temp file leaks, the
   --  temp file is registered for cleanup, and freeing the DB here would
   --  court the ada_sqlite3 double-finalize crash that Finalize avoids.
   procedure Spill (Self  : in out Backing_Store;
                    T     : in out Columns.Column_Maps.Map;
                    Name  : String;
                    Start : Positive);

   --  Read one cell from the spilled [data] table, materializing the whole
   --  containing segment into the prefetch cache on first access.  T and
   --  Row_Count give the table shape (column count for segment sizing).
   function Fetch (Self      : in out Backing_Store;
                   Row       : Positive;
                   Col       : String;
                   T         : Columns.Column_Maps.Map;
                   Row_Count : Natural) return SData_Core.Values.Value;

   --  Clear the segment prefetch cache (call before mutating a cached table).
   procedure Clear_Cache (Self : in out Backing_Store);

   --  Raw SQL escape hatch used by the Sort ORDER BY rebuild and the
   --  Commit_Output_Table table swaps -- operations that are inherently
   --  DB-level table create/drop/rename.  No-op-safe only when Is_Active.
   procedure Execute (Self : in out Backing_Store; SQL : String);

   --  Tear down: delete the temp file, deactivate, clear cache, unregister
   --  the cleanup path.  Idempotent.  Called by Table.Clear and by Finalize.
   procedure Close (Self : in out Backing_Store);

private

   type Database_Access is access all Ada_Sqlite3.Database;

   --  Input-segment prefetch cache: all rows of one spilled segment, keyed by
   --  SQLite column name, indexed by (row - Seg_Start + 1).
   package Seg_Data_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Columns.Value_Vectors.Vector,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=",
      "="             => Columns.Value_Vectors."=");

   type Backing_Store is new Ada.Finalization.Limited_Controlled with record
      DB         : Database_Access := null;
      Is_Active  : Boolean := False;
      Temp_Path  : Ada.Strings.Unbounded.Unbounded_String;
      Seg_Cache  : Seg_Data_Maps.Map;
      Seg_Start  : Natural := 0;  --  0 = empty; first logical row of cached segment
      Seg_End    : Natural := 0;  --  last logical row of cached segment
   end record;

   overriding procedure Finalize (Self : in out Backing_Store);

end SData_Core.Backing_Store;
