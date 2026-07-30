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
with Ada.Strings.Equal_Case_Insensitive;
with Ada.Strings.Hash;
with Ada.Strings.Hash_Case_Insensitive;
with Ada.Strings.Unbounded;
with Ada_Sqlite3;
with SData_Core.Columns;
with SData_Core.Config;
with SData_Core.Values;

package SData_Core.Backing_Store is

   type Backing_Store is tagged limited private;

   --  Create the temp DB and register it for signal cleanup.  Idempotent:
   --  no-op if already active.  Named Open rather than Initialize because a
   --  primitive named Initialize with this profile would OVERRIDE
   --  Limited_Controlled.Initialize and auto-run at object creation -- which
   --  would eagerly create the singleton's temp DB at elaboration, changing
   --  the on-demand behavior of the original Initialize_Backing_Store.
   --
   --  Latches the active spill schema (SData_Core.Config.Spill_Schema, or
   --  the SDATA_SPILL_SCHEMA environment variable override if set to "WIDE"
   --  or "EAV") for this store's whole lifetime -- a table already spilling
   --  under one schema must not switch mid-session if the config changes
   --  later (per the eav-spill-schema systems-designer review).
   procedure Open (Self : in out Backing_Store);

   function Is_Active (Self : Backing_Store) return Boolean;

   --  True when this store is spilling in the entity-attribute-value
   --  schema (ADR-0011) rather than the legacy one-column-per-data-column
   --  schema. Latched at Open; see Open's header comment.
   function Is_EAV (Self : Backing_Store) return Boolean;

   --  Resolve (never create) Column_Name's col_id in Name's EAV column
   --  registry ("data" | "output_data"). Returns 0 if Column_Name has never
   --  been spilled under Name (unknown column, or the store isn't in EAV
   --  mode). Callers needing "pivot by this sort key" access (Sorting) use
   --  this to find the col_id to filter on; see ADR-0011's second Amendment
   --  for why that pivot needs no SQL index of its own.
   function Col_Id (Self : Backing_Store; Name, Column_Name : String) return Natural;

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
   --  containing segment into the prefetch cache on first access.  T's column
   --  count drives segment sizing; Row_Count clamps the segment's upper bound.
   function Fetch (Self      : in out Backing_Store;
                   Row       : Positive;
                   Col       : String;
                   T         : Columns.Column_Maps.Map;
                   Row_Count : Natural) return SData_Core.Values.Value;

   --  Clear the segment prefetch cache (call before mutating a cached table).
   procedure Clear_Cache (Self : in out Backing_Store);

   --  Raw SQL escape hatch used by the Sort ORDER BY rebuild and the
   --  Commit_Output_Table table swaps -- operations that are inherently
   --  DB-level table create/drop/rename.
   --  PRECONDITION: only call when Is_Active.  This dereferences the DB handle
   --  unconditionally; calling it on an inactive store is a null dereference,
   --  not a no-op.  Every caller guards with `if Store.Is_Active`.
   procedure Execute (Self : in out Backing_Store; SQL : String);

   --  EAV only: Commit_Output_Table has SQL-level renamed output_data(_cols)
   --  onto data(_cols) (or dropped both if there was nothing to keep) --
   --  mirror that on the Ada-side col_id registries: "data"'s registry
   --  becomes what "output_data"'s was (correct whether or not anything was
   --  actually spilled to output_data: an unspilled output has an empty
   --  registry, which is exactly the fresh-start "data" needs going
   --  forward), and "output_data"'s registry resets empty. A no-op when not
   --  in EAV mode (the registries are unused and stay empty either way).
   procedure Commit_Output_Rename (Self : in out Backing_Store);

   --  EAV only: both dataset names' col_id registries are dropped (Table's
   --  "everything truncated to zero rows" branch of Commit_Output_Table,
   --  which drops both physical tables outright). A no-op when not in EAV
   --  mode.
   procedure Reset_Col_Ids (Self : in out Backing_Store);

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

   --  EAV column-name -> col_id registry, one instance each for "data" and
   --  "output_data" (see ADR-0011). Keyed case-insensitively, matching every
   --  other column-name lookup in this crate (Fetch's U_Col upper-casing,
   --  Columns.Column_Name's own case-folding).
   package Col_Id_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Positive,
      Hash            => Ada.Strings.Hash_Case_Insensitive,
      Equivalent_Keys => Ada.Strings.Equal_Case_Insensitive);

   type Backing_Store is new Ada.Finalization.Limited_Controlled with record
      DB         : Database_Access := null;
      Is_Active  : Boolean := False;
      Temp_Path  : Ada.Strings.Unbounded.Unbounded_String;
      Seg_Cache  : Seg_Data_Maps.Map;
      Seg_Start  : Natural := 0;  --  0 = empty; first logical row of cached segment
      Seg_End    : Natural := 0;  --  last logical row of cached segment

      --  Latched at Open; see Open's header comment.
      Schema : SData_Core.Config.Spill_Schema_Kind := SData_Core.Config.Spill_EAV;

      --  EAV bookkeeping (unused, stays empty, when Schema = Spill_Wide).
      Data_Col_Ids     : Col_Id_Maps.Map;
      Data_Next_Id     : Positive := 1;
      Output_Col_Ids   : Col_Id_Maps.Map;
      Output_Next_Id   : Positive := 1;
   end record;

   overriding procedure Finalize (Self : in out Backing_Store);

end SData_Core.Backing_Store;
