---
id: ADR-0011
title: "Disk spill moves from one-SQLite-column-per-data-column to an EAV schema"
status: Proposed
date: 2026-07-28
related:
  - ../../sdata/doc/design.md
  - ../../sdata/.ssd/features/eav-spill-schema/01-architect.md
---

# ADR-0011: Disk spill moves from one-SQLite-column-per-data-column to an EAV schema

## Status

Proposed. This is the architecture spec for sdata issue
[jlries61/sdata#64](https://github.com/jlries61/sdata/issues/64); no
implementation has landed yet.

## Context

`SData_Core.Backing_Store.Spill`/`Fetch` (`sdata_core-backing_store.adb`)
currently map every in-memory data column 1:1 to a SQLite table column:
`CREATE TABLE [data] (record_id INTEGER PRIMARY KEY, <col1> REAL, <col2>
INTEGER, ...)`. SQLite's own `SQLITE_MAX_COLUMN` (default 2000) therefore
caps how wide a table can get before `-m`-triggered spill fails outright.
sdata's `design.md` §1.1 states "no hard memory or dimensional constraints"
as a requirement; §2.1 documents this ~2000-column ceiling as the one known
exception, annotated (not folded into the requirement's own wording — see
`design.md` commit 4b222b1) as a gap the project intends to close before its
1.0 release.

`SData_Core.Sorting`'s disk-path rebuild (`sdata_core-sorting.adb`) and
`SData_Core.Table.Commit_Output_Table`'s table-swap both also assume this
wide-table shape (`SELECT * ... ORDER BY <col>`, `ALTER TABLE ... RENAME
TO`), so removing the ceiling touches those two call sites as well as
`Backing_Store` itself.

## Decision

Replace the wide per-dataset SQLite table with a narrow, column-count-
independent entity-attribute-value (EAV) schema, per dataset name
(`data` / `output_data`):

```sql
CREATE TABLE IF NOT EXISTS [<name>_cols] (
  col_id   INTEGER PRIMARY KEY,
  col_name TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS [<name>] (
  record_id INTEGER NOT NULL,
  col_id    INTEGER NOT NULL,
  val_num   REAL,
  val_int   INTEGER,
  val_txt   TEXT,
  PRIMARY KEY (record_id, col_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS [<name>_by_col] ON [<name>] (col_id, record_id);
```

Key properties:

- **No per-dataset DDL scales with column count.** `<name>_cols` grows by
  *rows*, not SQL columns, as the dataset gets wider — it never touches
  `SQLITE_MAX_COLUMN` regardless of how many data columns exist.
- **Missing is sparse, not a stored NULL.** A cell is Missing iff no
  `(record_id, col_id)` row exists for it — there is no `kind`/NULL-sentinel
  column. `Fetch`'s existing "absent -> `Val_Missing`" default (already true
  today) becomes the *storage* mechanism, not just the read-side default.
  This also means storage cost scales with non-missing cell count, which is
  a genuine improvement for sparse (long/wide, mostly-missing) datasets and
  a genuine cost for fully dense ones — see Consequences.
- **`col_id` interning avoids repeating column-name text per cell.** Storing
  `col_name` directly in every EAV row would multiply a potentially-long
  string by every row × every populated column; the `<name>_cols` lookup
  table stores the name once and every value row carries a small integer.
- **Column type comes from the in-memory schema, not a per-row tag.**
  `SData_Core.Columns.Column_Type` is fixed for a column's lifetime and
  already known to both `Spill` and `Fetch` via the `T : Column_Maps.Map`
  parameter both already receive — so which of `val_num`/`val_int`/`val_txt`
  is meaningful for a given `col_id` is looked up from `T`, not stored
  per-cell.

### Call-site changes

- **`Spill`**: instead of one wide `INSERT ... VALUES (?, ?, ...)` per
  record (N binds), one narrow `INSERT INTO [<name>] (record_id, col_id,
  val_num|val_int|val_txt) VALUES (?, ?, ?)` per **non-missing** cell,
  still batched in one `BEGIN`/`COMMIT` transaction. `col_id`s are
  resolved/created once against `<name>_cols` before the row loop (same
  cost class as today's one-time `Col_Names`/`Col_Cursors` snapshot).
- **`Fetch`**: the segment query becomes
  `SELECT v.record_id, v.col_id, v.val_num, v.val_int, v.val_txt FROM
  [<name>] v WHERE v.record_id BETWEEN ? AND ? ORDER BY v.record_id`
  (joined against `<name>_cols` once to resolve `col_id -> col_name`, or
  resolved into a small in-memory map before the query, since the column
  set is bounded by the in-memory schema, not the row count). Per-column
  cache vectors are now pre-filled `Val_Missing` for the whole segment
  length (from `T`'s known column set) and overwritten at
  `record_id - S_Start + 1` for cells the query actually returns, rather
  than populated by sequential `Append` from a dense wide row.
- **`Sorting`'s disk-path rebuild**: cannot `ORDER BY <col>` directly (the
  column is spread across rows, not present as a SQL column). Replaced
  with: (1) pivot *only the active sort/BY key columns* — always a small,
  bounded set, never approaching the old ceiling — into a temporary
  `sort_map(old_id, new_id)` table via one `LEFT JOIN` per sort key plus
  `ROW_NUMBER() OVER (ORDER BY ...)`; (2) `CREATE TABLE data_new AS SELECT
  sort_map.new_id, v.col_id, v.val_num, v.val_int, v.val_txt FROM [data] v
  JOIN sort_map ON v.record_id = sort_map.old_id`; (3) `DROP TABLE data;
  ALTER TABLE data_new RENAME TO data` — the same drop/rename swap pattern
  already used today, just building `data_new` from an EAV-to-EAV copy
  instead of a wide `SELECT * ... ORDER BY`.
- **`Commit_Output_Table`**: unchanged in spirit and *simpler* in practice —
  the existing `DROP TABLE`/`ALTER TABLE ... RENAME TO` swap between
  `data`/`output_data` (and now their paired `_cols` tables) never depended
  on column count and continues not to.
- **`Rename_Column`/`Drop_Column`**: today these touch only the in-memory
  `Data_Table` map and never reach the backing store at all — a column
  renamed or dropped after some segments have already spilled is invisible
  to those segments' stored data. The EAV schema makes correctly wiring
  this up cheap (`UPDATE [<name>_cols] SET col_name = ? WHERE col_name = ?`;
  `DELETE FROM [<name>] WHERE col_id = ?`), but wiring it up is **out of
  scope for this ADR** — noted as a pre-existing, orthogonal gap that this
  schema change happens to make easy to close later, not a requirement of
  closing #64.

### Rollout

An internal, undocumented toggle (`SData_Core.Config.Runtime.Spill_Schema
: Spill_Schema_Kind := EAV`, or equivalent env var) keeps the old wide-table
code path selectable for one release cycle after the EAV path ships,
so a field regression can be worked around without a full revert. The old
path is deleted once the EAV path has shipped in one sdata + one data-vandal
release with no regressions reported.

## Rationale

The alternatives considered:

1. **Raise `SQLITE_MAX_COLUMN` at compile time.** SQLite hard-caps this at
   32767 regardless of build flags, and even the friendlier ceiling still
   reintroduces a fixed wall — it does not satisfy design.md §1.1's "no
   hard... dimensional constraints" so much as move it. Rejected.
2. **Multiple wide tables, striped every ~1900 columns.** Keeps the
   per-column-affinity schema (simpler `Spill`/`Fetch` diffs) but every
   other operation (`Sort`, cross-stripe `Fetch`, `Commit_Output_Table`)
   has to reason about which stripe a column lives in, and the ceiling
   reappears as soon as the striping constant is undercounted for some
   future dataset. Rejected as a workaround that doesn't resolve the
   requirement, just relocates it.
3. **EAV schema (this decision).** Genuinely removes the ceiling (the
   `_cols` table scales by rows, not SQL columns), and turns out to
   *simplify* `Commit_Output_Table` (no per-column DDL ever) at the cost of
   a real rework of `Spill`/`Fetch`'s row shape and a materially different
   `Sort` rebuild strategy. Accepted.

## Consequences

**Positive**

- Removes the ~2000-column spill ceiling entirely — closes sdata issue #64
  and lets `design.md` §1.1 drop its Note/caveat once shipped.
- Sparse (mostly-missing-cell) datasets use less spill storage than today,
  since a missing cell is simply an absent row rather than a stored NULL
  across a wide row.
- `Commit_Output_Table`'s table swap gets *simpler*, not harder — no
  column-count-dependent DDL of any kind.
- Makes a correct backing-store-aware `Rename_Column`/`Drop_Column`
  (today silently not wired to the store at all) cheap to add later, though
  that's explicitly not bundled into this change.

**Negative**

- `Spill` issues one `INSERT`/non-missing-cell instead of one `INSERT`/row
  — more `Stmt.Reset`/bind/`Step` cycles for the same data volume on dense
  (few-missing) datasets. Must be benchmarked, not assumed free; see Risk
  Assessment in the architect spec for the perf-regression gate this
  requires before shipping.
- Fully dense wide datasets may see larger on-disk spill size than today
  (per-cell `(record_id, col_id)` PK overhead vs. one wide row amortizing a
  single `record_id` over many columns) even after `col_id` interning —
  also to be benchmarked, not asserted.
- `Sort`'s disk-path rebuild is materially more complex (pivot + window
  function + join-based copy) than today's `SELECT * ... ORDER BY`.
- Requires SQLite window-function support (`ROW_NUMBER() OVER`), available
  since SQLite 3.25 (2018) — not expected to be a real constraint given the
  `ada_sqlite3` binding already in use, but worth confirming against the
  bundled SQLite version during implementation.

## Related

- sdata issue [#64](https://github.com/jlries61/sdata/issues/64)
- sdata `design.md` §1.1 (commits 3c85fb0, 4b222b1, ff157c0) and §2.1
- sdata `.ssd/features/eav-spill-schema/01-architect.md` (architect spec,
  full data model / component diagram / risk assessment)
