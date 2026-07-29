---
id: ADR-0011
title: "Disk spill moves from one-SQLite-column-per-data-column to an EAV schema"
status: Proposed (amended 2026-07-29 twice — persistent secondary index dropped, Sort pivot needs no index either, both per benchmark)
date: 2026-07-28
related:
  - ../../sdata/doc/design.md
  - ../../sdata/.ssd/features/eav-spill-schema/01-architect.md
  - ../../tests/spill_schema_benchmark.adb
---

# ADR-0011: Disk spill moves from one-SQLite-column-per-data-column to an EAV schema

## Status

Proposed. This is the architecture spec for sdata issue
[jlries61/sdata#64](https://github.com/jlries61/sdata/issues/64); no
implementation has landed yet. **Amended 2026-07-29, twice** (see the two
"Amendment" sections near the end): (1) the original schema's persistent
`[<name>_by_col]` secondary index is dropped after a benchmark found it
caused insert time to blow up 63x for a 2x column-count increase; (2) the
sort-key pivot access pattern that index existed for turns out to need no
index at all — a plain filtered table scan per sort-key column benchmarks
faster than any indexed alternative at every scale tested. Everything
below the amendments reflects the original proposal for context; the
amendments are the current recommendation.

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

**Superseded by the 2026-07-29 amendment below: drop the `[<name>_by_col]`
index.** A benchmark found it causes a 63x insert-time blowup for a 2x
column-count increase (up to 14.4 hours at 20,000 columns) with zero
benefit to `Spill`/`Fetch`, which never used it. Kept here only so the
"Call-site changes" and "Rationale" sections below still read in the order
they were originally reasoned through; see § "Amendment" for the current
schema and decision.

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
  bounded set, never approaching the old ceiling — via one plain `SELECT
  record_id, val_num|val_int|val_txt FROM [<name>] WHERE col_id = <N>`
  scan per sort key (**benchmarked 2026-07-29b: no index needed, see the
  second Amendment below** — this was originally specified as a `LEFT
  JOIN` against a persistent secondary index, corrected here), assembled
  into a temporary `sort_map(old_id, new_id)` table via
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
  (few-missing) datasets. **Benchmarked 2026-07-29 — see § "Amendment"
  below.** The naive schema (with the persistent secondary index) was
  catastrophically not free at width; the amended (index-free) schema
  scales near-linearly and is comparably fast to the wide schema at
  widths the wide schema can also reach (e.g. 1,900 cols).
- Fully dense wide datasets may see larger on-disk spill size than today
  (per-cell `(record_id, col_id)` PK overhead vs. one wide row amortizing a
  single `record_id` over many columns) even after `col_id` interning —
  also to be benchmarked, not asserted.
- `Sort`'s disk-path rebuild is materially more complex (pivot + window
  function + join-based copy) than today's `SELECT * ... ORDER BY` — though
  the pivot step itself turns out simpler than expected: **benchmarked
  2026-07-29b — see the second "Amendment" below** — no index of any kind
  is needed for it, just a plain filtered scan per sort-key column.
- Requires SQLite window-function support (`ROW_NUMBER() OVER`), available
  since SQLite 3.25 (2018) — not expected to be a real constraint given the
  `ada_sqlite3` binding already in use, but worth confirming against the
  bundled SQLite version during implementation.

## Amendment (2026-07-29): drop the persistent `[<name>_by_col]` secondary index

Per the user's request to de-risk this proposal with real numbers before
implementation, `tests/spill_schema_benchmark.adb` (a standalone spike
driver, not part of `run-tests.sh` — see `tests/README.md`) was built
against the real `Ada_Sqlite3`/`Ada_Sqlite3.Wide` bindings and the same
connection `PRAGMA`s as `Backing_Store.Open`, comparing the current wide
schema against this ADR's original EAV proposal (schema exactly as
specified above, including the secondary index) across column widths from
50 to 20,000, at 2000 rows, dense and 75%-missing.

**Headline result:** EAV insert time did not degrade smoothly. It blew up
63x for a 2x column-count increase, while file size grew only ~2x:

| Cols (dense, 2000 rows) | Insert time | File size |
|---|---|---|
| 1,900 | 10.6 sec | 135 MB |
| 5,000 | 104 sec | 357 MB |
| 10,000 | 818 sec (13.6 min) | 714 MB |
| 20,000 | **51,785 sec (14.4 hours)** | 1,429 MB |

A follow-up pass isolated the cause: the `[data_by_col] (col_id,
record_id)` secondary index, maintained continuously during a record_id-
major insert (the natural order data arrives in — one full record at a
time), forces every row's insert to touch `Cols` scattered, far-apart
regions of that index (one per distinct `col_id`) instead of one
contiguous region. Once the total working set outgrows the connection's
64 MB `cache_size`, this becomes a cache miss (and a B-tree page split) on
almost every single-cell insert. Fetch time was essentially unaffected in
every variant below, confirming the index was pure insert-time cost with
**no** benefit to the segment-range read path this benchmark exercises
(`Fetch` was already served by the primary key, never the secondary
index):

| Variant (20,000 cols, dense) | Insert time | vs. original |
|---|---|---|
| Original (index present, record_id-major insert) | 51,785 sec | — |
| Index dropped entirely | 30 sec | **1,724x faster** |
| Index present, column-major insert order | 212 sec | 244x faster |

Dropping the index outright restores near-linear scaling (17.4 sec ->
30 sec, 10,000 -> 20,000 cols, tracking the ~2x file-size growth) and is
strictly better than reordering the insert loop to match the index's
clustering key — reordering helps a lot but the index maintenance cost is
still there and still shows some superlinearity.

Critically, the degradation is not only an extreme-scale concern: the
5,000 -> 10,000 column step (both already comfortably past today's actual
~2000-column ceiling, i.e. within the width range this feature exists to
serve) already shows 7.8x insert time for a 2x column increase — already
superlinear, just not yet catastrophic. **The persistent secondary index
as originally specified is not viable at the widths this feature targets,
not merely at extreme stress-test widths.**

### Revised decision

Drop `CREATE INDEX IF NOT EXISTS [<name>_by_col] ON [<name>] (col_id,
record_id);` from the schema entirely. `Spill`/`Fetch` are unaffected — they
were never served by this index. The one caller that motivated it,
`Sorting`'s sort-key pivot (see § "Call-site changes" above), must instead
either (a) build a **temporary** index scoped to just the active sort/BY
key columns immediately before a disk-path sort and drop it right after —
paying the maintenance cost only for the rare Sort operation and only for
the small number of sort-key columns, not the whole table on every insert
— or (b) pivot via a full `[<name>]` table scan filtered by `col_id = ?`
per sort key (no index at all; cost is O(spilled cells) per sort-key
column, paid once per `Sort`/`BY` execution rather than continuously).
**Which of (a) or (b) is faster has not been benchmarked** — that is
follow-up work before `Sorting`'s implementation, not before `Spill`/
`Fetch`'s, since those two are now unblocked by this amendment. `Spill`/
`Fetch` may proceed against the amended (index-free) schema immediately.

This also resolves one of the two open items in the original Consequences
section below: the "must be benchmarked, not assumed free" insert-
throughput risk is now benchmarked, and the answer is "assumed free was
wrong for the original schema, corrected by dropping the index." The
on-disk-size risk remains only partially answered — dense-dataset file
size at 20,000 columns dense is 1,429 MB (with index) vs. 961 MB (without)
for 40M cells (~24-36 bytes/cell either way), not compared against an
equivalent wide-table baseline at that width since the wide schema cannot
reach 20,000 columns at all (the whole point of this change) — there is no
"before" number to compare against past 1,900 columns.

Full raw data: `tests/spill_schema_benchmark_results.csv` (original
18-combo matrix) and `tests/spill_schema_benchmark_followup.csv` (the
4-combo index/insert-order isolation pass).

## Amendment (2026-07-29b): Sorting's sort-key pivot needs no index at all

The previous amendment left one question open: how should `Sorting`'s
sort-key pivot (fetch every value of a given column, across all records)
be served without a persistent index? Two candidates were proposed: (a) a
temporary index — either scoped to the full table or just the sort-key
columns — built immediately before a disk-path sort and dropped right
after, or (b) a plain filtered table scan per sort-key column, no index at
all. `spill_schema_benchmark.adb` was extended to measure both, against an
already-populated, index-free EAV table, at 1,900–20,000 columns and
K = 1 or 5 sort-key columns (a realistic `BY`/`SORT` key count):

| Cols | K | No index (K scans) | Full temp index | Partial temp index (scoped to K cols) |
|---|---|---|---|---|
| 1,900 | 1 | **160 ms** | 2,809 ms | 434 ms |
| 1,900 | 5 | **1,312 ms** | 3,015 ms | 3,693 ms |
| 5,000 | 1 | **383 ms** | 5,645 ms | 791 ms |
| 5,000 | 5 | **1,949 ms** | 6,212 ms | 7,374 ms |
| 10,000 | 1 | **746 ms** | 21,521 ms | 1,547 ms |
| 10,000 | 5 | **4,083 ms** | 12,402 ms | 14,210 ms |
| 20,000 | 1 | **2,375 ms** | 27,806 ms | 3,092 ms |
| 20,000 | 5 | **7,822 ms** | 23,861 ms | 28,538 ms |

**No index at all wins at every scale and every K tested**, usually by a
wide margin. The reason generalizes cleanly: building *any* index — even
one scoped to just the K sort-key columns via a partial-index `WHERE
col_id IN (...)` clause — still requires SQLite to scan the *entire* base
table once to decide which rows qualify. Since each sort-key column in
this access pattern is only queried once (immediately after the index
would be built, to populate the sort-key pivot), that one-time index-build
scan is strictly worse than just doing the K plain scans directly — there
is no repeated-query workload here to amortize an index's build cost
against. This holds even at K = 5 and even at 20,000 columns: a full
index build alone (27.8 sec) costs more than the *entire* five-column
no-index pass (7.8 sec). No-index time also scales close to linearly with
total cell count (160 ms → 2,375 ms for a ~10.5x increase in cells, cols
1,900 → 20,000 at K = 1), with no cliff of the kind the original secondary
index produced.

**Decision:** `Sorting`'s disk-path sort-key pivot uses a plain, literal
(not bound-parameter) `SELECT record_id, val_num|val_int|val_txt FROM
[<name>] WHERE col_id = <N>` per sort/BY key column — no temporary index
of any kind. This is both the fastest measured option and the simplest to
implement (no index create/drop lifecycle to manage around the pivot).
The `ROW_NUMBER() OVER (ORDER BY ...)` window-function step used to turn
the pivoted values into a `sort_map(old_id, new_id)` (see § "Call-site
changes" above) is unaffected by this — it operates on the pivoted result,
not on how that result was fetched.

Raw data: `tests/spill_schema_benchmark_sortpivot.csv`.

## Related

- sdata issue [#64](https://github.com/jlries61/sdata/issues/64)
- sdata `design.md` §1.1 (commits 3c85fb0, 4b222b1, ff157c0) and §2.1
- sdata `.ssd/features/eav-spill-schema/01-architect.md` (architect spec,
  full data model / component diagram / risk assessment)
- `tests/spill_schema_benchmark.adb` + `tests/spill_schema_benchmark_results.csv`
  + `tests/spill_schema_benchmark_followup.csv` + `tests/spill_schema_benchmark_sortpivot.csv`
  (benchmark spike backing both 2026-07-29 amendments)
