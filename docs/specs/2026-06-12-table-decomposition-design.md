# Design Spec — Decompose `SData_Core.Table` (audit U1, with J1-internal)

- **Status:** approved design, not yet implemented
- **Date:** 2026-06-12
- **Audit items:** U1-after (`Table` god-package), J1-after (internal half — `Column_Name`)
- **Decision record:** [ADR-0007](../decisions/ADR-0007-decompose-table-package.md)
- **Implements for:** a future session, milestone by milestone

## 1. Problem

`SData_Core.Table` is a god-package: `src/sdata_core-table.adb` is ~1,269 LOC and
`src/sdata_core-table.ads` ~249 LOC, owning at least seven distinct
responsibilities behind one body and one pile of package-level mutable state:

| Cluster | Representative ops | Approx LOC |
|---|---|---|
| Spill / backing store | `Spill_Table_To_Disk` (81), `Fetch_From_Disk` (91), `Initialize_Backing_Store` (27), `Backing_Store` type, `Seg_Cache`, `Sql_Id`, `Img` | ~230 |
| Sort | `Sort` (157) + dealloc helpers, `Sort_Criteria` | ~175 |
| Schema / columns | `Add_Column`, `Has_Column`, `Get_Column_Type`, `Column_Count`, `Column_Name`, `Rename_Column`, `Drop_Column`, cursor cache | |
| Values | `Get_Value(_Upper/_By_Col)`, `Set_Value(_Upper/_By_Col)`, `Coerce_Value` | |
| Output table | `Initialize_Output_Table`, `Add_Output_Column`, `Add/Set_Output_*`, `Commit_Output_Table`, `Upgrade_Placeholder_Type` | |
| BY-group | `Clear/Add_By_Var`, `By_Var_Count/Name`, `In_Same_Group` | ~25 |
| Filter map + record pointers | `Set/Clear_Index_Map`, `Logical_To_Physical`, current/logical record indices | |

It also carries the **J1** column-name representation sprawl. Per the
2026-06-12 scoping decision, J1's *internal* half (the private representations)
is folded into this work; J1's *public* tail (`Sort_Criteria`, `Name_Vectors`)
is explicitly out of scope (see §8).

Uncle Bob's recommendation (audit): *"Extract a `Table.Spill` /
`Table.Backing_Store` sub-package operating on `(T : Column_Maps.Map, Name,
Start)`, with Data and Output as two clients … then peel off Sort and the
BY-group helpers. Multi-milestone, not a blocker."*

## 2. Scope (locked decisions)

- **Internal-only.** `SData_Core.Table` keeps its **exact public API**. No
  consumer (`sdata`, `data-vandal`) source changes. **No version bump.**
- **Target mechanism:** real encapsulation — an owned `Backing_Store` object
  with parameterized operations, not code merely relocated over shared globals.
- **`Column_Name`** is introduced as a **private internal type** (closes
  J1-internal). The public name-bearing types (`Sort_Criteria`,
  `Name_Vectors`) are **not** touched.
- Behavior is **identical** at every milestone; the gate is the in-crate
  drivers plus both consumer suites.

### Non-goals

- The J1 *public* tail (`Sort_Criteria.Name+Len`, `Table.Name_Vectors` via
  `Commands.Execute_ARRAY`). Remains a documented known-gap; would need an ADR
  for the break + coordinated consumer edits + a version bump.
- K5-after (single-segment cache → LRU). The extracted `Backing_Store` makes it
  a localized future change but does not implement it.
- Any behavioral or performance change. This is a structure-only refactor.

## 3. Key facts the design relies on (verified at HEAD)

- **One shared `Store`.** `Spill_To_Disk` writes `Data_Table` → SQLite table
  `"data"`; `Spill_Output_To_Disk` writes `Output_Data_Table` → `"output_data"`;
  both use the **same** `Store` (one temp DB, two tables). `Spill_Table_To_Disk
  (T, Name, Start)` is already parameterized.
- **Read cache is input-only.** `Fetch_From_Disk` + `Seg_Cache` /
  `Seg_Start` / `Seg_End` serve only the input `Data_Table`; the output table is
  write-then-`Commit_Output_Table`, never segment-fetched. ⇒ a **single**
  `Backing_Store` instance (DB + one read cache) is correct, not two.
- **State lives in the spec's private part** (`table.ads:160-243`):
  `Data_Table`, `Output_Data_Table`, `Column_Order`, cursor caches, `Seg_Cache`,
  `Store`, segment bounds, row counts. Today this is reachable by any child
  package.
- **Consumers depend on `Column_Type` literals.** `SData_Core.Table.Col_String`
  / `Col_Numeric` / `Col_Integer` are referenced directly at 16 sites across
  `sdata` (`merge.adb`, `transient_table.*`), and `SData_Core.Table.Column_Type`
  at 23. Any relocation of `Column_Type` **must** preserve
  `SData_Core.Table.Col_*` exactly.

## 4. Target architecture

```
SData_Core.Columns        (new, foundational, independent)
   Column_Type            -- moved here
   Column_Name            -- new private type (Unbounded_String-backed, upper-cased)
   Value_Vectors          -- Vectors (Positive, Values.Value)
   Column                 -- record { Name : Column_Name; Typ; Data; Type_Is_Placeholder }
   Column_Maps            -- Indefinite_Hashed_Maps keyed by Column_Name

SData_Core.Backing_Store  (new, independent; with Columns)
   type Backing_Store     -- owns { DB, Temp_Path, Is_Active, Seg_Cache, Seg_Start/End }
   Initialize / Spill / Fetch / Path / Clear_Cache / Finalize  -- take (map, name, start, ...)
   -- compiler-enforced: cannot see Table's globals

SData_Core.Sorting        (new; with Columns)   -- milestone M4  (see §4.4)
SData_Core.Grouping       (new; with Columns)   -- milestone M5  (see §4.4)

SData_Core.Table          (facade; public API UNCHANGED)
   -- with Columns, Backing_Store, Sorting, Grouping
   -- holds state (incl. one Backing_Store instance); delegates
   subtype Column_Type is Columns.Column_Type;
   function Col_Numeric return Column_Type renames Columns.Col_Numeric;  -- + Col_Integer, Col_String
   -- Sort_Criteria, Sort_Direction, Index_Array, Name_Vectors,
   -- Type_Mismatch_Error all stay here unchanged
```

### 4.1 `Column_Type` re-export shim (preserves the public API)

`Column_Type` moves to `SData_Core.Columns`; `SData_Core.Table` re-exports it so
no consumer changes:

```ada
--  in SData_Core.Table's visible part, after `with SData_Core.Columns;`
subtype Column_Type is SData_Core.Columns.Column_Type;
function Col_Numeric return Column_Type renames SData_Core.Columns.Col_Numeric;
function Col_Integer return Column_Type renames SData_Core.Columns.Col_Integer;
function Col_String  return Column_Type renames SData_Core.Columns.Col_String;
function "=" (Left, Right : Column_Type) return Boolean
  renames SData_Core.Columns."=";   -- REQUIRED, see below
```

Enumeration literals are parameterless functions, so they rename cleanly, and a
`subtype` keeps `use type SData_Core.Table.Column_Type;` callers compiling. **But
the subtype + literal renames are NOT sufficient on their own** (corrected during
M1 implementation, 2026-06-13): the enumeration's predefined `"="` moves to
`SData_Core.Columns` with the base type, so a consumer doing `use
SData_Core.Table;` *without* a `use type` clause loses direct visibility of `=`
and fails to compile (e.g. `sdata`'s `tests/sdata_unit_test.adb` does
`Get_Column_Type ("X") = SData_Core.Table.Col_Numeric` under a package-wide
`use`). Re-exporting `"="` from `Table`'s visible part restores the prior
directly-visible operator set, so both consumers build untouched. A tree-wide
grep confirmed only `=` is used on `Column_Type` (no ordering operators, no
`/=`), so the single `"="` rename is the minimal sufficient set; `/=` is
auto-derived from a visible `=`. **The same correction applies to any other
enum/record relocated behind this shim — see §4.4 for `Sort_Direction` /
`Sort_Criteria` in M4.**

> **Forward caution (M2–M5):** because the re-exported `Col_*` are now
> *functions*, not enumeration literals, they cannot appear in a *static* context
> — `case … when Col_X =>` choices, `Column_Type'Image`/`'Pos`/`'Val`, a `for
> Column_Type use (…)` rep clause, or an array aggregate keyed by the literals.
> M1 is safe (no such use exists tree-wide). If a later milestone needs one, this
> shim won't satisfy it and the relocation strategy for that type must change.

### 4.2 `Column_Name` (closes J1-internal)

```ada
--  SData_Core.Columns
type Column_Name is private;
function To_Column_Name (S : String) return Column_Name;   -- THE upper-casing chokepoint
function Image (N : Column_Name) return String;            -- back to String when needed
function "=" (L, R : Column_Name) return Boolean;
function Hash (N : Column_Name) return Ada.Containers.Hash_Type;
private
   type Column_Name is record
      Value : Ada.Strings.Unbounded.Unbounded_String;       -- always upper-cased
   end record;
```

`Column.Name`, the `Column_Maps` key, and `Column_Order` /
`Output_Column_Order` all become `Column_Name`. Every `To_Upper (...)` /
padded-`String(1..Max_Name_Len)` / `To_Unbounded_String (...)` conversion on a
column name collapses into `To_Column_Name` / `Image`. The public API still
takes/returns `String` — the facade converts at the boundary.

### 4.3 `Backing_Store` interface (sketch)

```ada
--  SData_Core.Backing_Store
type Backing_Store is limited private;   -- Limited_Controlled; Finalize deletes the temp file

procedure Initialize (Self : in out Backing_Store);
procedure Spill (Self  : in out Backing_Store;
                 T     : in out Columns.Column_Maps.Map;
                 Name  : String;            -- "data" | "output_data"
                 Start : Positive);
function  Fetch (Self      : in out Backing_Store;
                 Row       : Positive;
                 Col       : String;
                 T         : Columns.Column_Maps.Map;   -- for column count / shape
                 Row_Count : Natural) return Values.Value;
function  Path (Self : Backing_Store) return String;    -- "" if inactive
procedure Clear_Cache (Self : in out Backing_Store);
overriding procedure Finalize (Self : in out Backing_Store);
```

The single `Store` instance in `SData_Core.Table` absorbs today's `Seg_Cache` /
`Seg_Start` / `Seg_End`. The atomicity / clean-abort contract currently
documented above `Spill_Table_To_Disk` (`table.adb:1043-1074`) **moves verbatim**
onto `Backing_Store.Spill`; the `Add_Row` cost-class doc (table.ads, item K4)
keeps pointing at it.

`Sql_Id` (SQL identifier quoting) is backing-store-specific and moves with it.
`Img` (the trim-leading-space integer formatter, `table.adb:25-29`) is **not**
backing-store-specific — it formats the `[table=…, rows=…]` context for spill,
sort, output-commit, and init errors alike. Do **not** move `Img` exclusively
into `Backing_Store`; promote it to a tiny shared home (the simplest is a
private helper in `SData_Core.Columns`, which every unit already `with`s) and
have each cluster call the one copy.

### 4.4 `Sorting` and `Grouping` have Table-ward dependencies (decide at the milestone)

`Backing_Store` is cleanly independent — it is the kernel and the main prize.
`Sorting` and `Grouping` are not as clean, and the implementing session must
pick a resolution at M4 / M5:

- **`Sorting`** needs `Sort_Criteria` / `Sort_Direction`, which today live in
  `SData_Core.Table`'s *visible* part (consumers build `Sort_Criteria_Array`).
  An independent `SData_Core.Sorting` cannot `with Table` (Table `with`s it).
  **Recommended:** relocate `Sort_Criteria` / `Sort_Direction` to
  `SData_Core.Columns` and re-export from `Table` with the same shim pattern as
  `Column_Type` — `subtype Sort_Criteria is Columns.Sort_Criteria;`,
  `subtype Sort_Direction is …;`, plus literal renames for `Ascending` /
  `Descending`. **Apply the §4.1 operator-re-export correction here too:** grep
  the consumers for how they compare `Sort_Direction` (e.g. `Dir = Ascending`)
  and `Sort_Criteria`, and re-export each operator used under a plain `use
  SData_Core.Table` — at minimum `"=" (Sort_Direction)` — or the M4 consumer
  build will break exactly as M1's did. Consumer aggregates and `use type` keep
  working. *Alternative:*
  make `Sorting` a private child of `Table` (sees the public types + private
  state) — simpler but trades away the compiler-enforced isolation.
- **`Grouping`**: `In_Same_Group` reads cell values through Table's value
  accessor (`Get_Value_Upper`). An independent unit cannot call back into
  Table. **Recommended:** pass `Grouping` the column map (and, if needed, the
  cursor cache) and have it read values via `Columns.Column_Maps` directly, the
  way `Get_Value_By_Col` already resolves a cell; the BY-var name list
  (`Column_Name` values) is passed in too. *Alternative:* child package.

If either alternative (child package) is chosen, say so in that milestone's PR
and in ADR-0007's "Consequences"; the facade and public API are unaffected
either way.

## 5. Milestone plan

Each milestone is independently shippable, behavior-preserving, and gated by:
`tests/run-tests.sh` (in-crate) **and** `cd ../sdata && make check` **and**
`cd ../data-vandal && make check`. None bumps the version. Commit each as its
own PR.

### M1 — `SData_Core.Columns` foundation (relocate, no rep change)

- Create `src/sdata_core-columns.ads/.adb`. Move `Value_Vectors`, `Column_Type`,
  `Column`, `Column_Maps` there. **Name representation unchanged** (still padded
  `String (1 .. Max_Name_Len)` in `Column.Name`, `String` map key) to isolate
  risk.
- Add the §4.1 re-export shim to `SData_Core.Table`; replace the moved
  declarations in its private part with `with`/use of `Columns`.
- Gate. The single most important check: **both consumers build and pass with
  zero source changes** — proves the shim.

### M2 — `Column_Name` type (closes J1-internal)

- Add `Column_Name` + `To_Column_Name`/`Image`/`"="`/`Hash` to `Columns`
  (§4.2). Re-key `Column_Maps` on `Column_Name`.
- Convert `Column.Name`, `Column_Order`, `Output_Column_Order`, and `Table_By_Vars`
  to `Column_Name`; route every column-name conversion through
  `To_Column_Name` / `Image`. Public API still `String`; facade converts.
- Drop now-dead `Max_Name_Len` padding logic for column names where it existed
  only for storage.
- Gate.

### M3 — `SData_Core.Backing_Store` extraction (the kernel, ~230 LOC out of Table)

- Create `src/sdata_core-backing_store.ads/.adb` with §4.3. Move
  `Spill_Table_To_Disk`, `Fetch_From_Disk`, `Initialize_Backing_Store`,
  `Sql_Id`, the `Backing_Store` record, and the segment-cache state + bounds.
  Carry the atomicity contract comment verbatim. Promote `Img` to its shared
  home first (§4.3) rather than moving it here.
- `SData_Core.Table` holds one `Backing_Store` instance and delegates:
  `Spill_To_Disk` → `Store.Spill (Data_Table, "data", Current_Segment_Start)`;
  `Spill_Output_To_Disk` → `Store.Spill (Output_Data_Table, "output_data",
  Output_Segment_Start)`; the value accessors call `Store.Fetch (...)` when a row
  is spilled. `Get_Backing_Store_Path` → `Store.Path`. Finalization path
  (signal cleanup) unchanged in observable effect.
- Preserve the structured-error context (`[table=…, rows=…, segment_start=…]`)
  exactly.
- Gate. Spot-check: a spill-triggering dataset (small `Max_Table_Cells`) reads
  back identically; the temp file is still deleted on exit and on SIGINT.

### M4 — `SData_Core.Sorting` extraction (~175 LOC)

- Resolve the `Sort_Criteria` / `Sort_Direction` dependency first (§4.4):
  recommended path is to relocate them to `SData_Core.Columns` + Table
  re-export shim. Then move `Sort` and its `Unchecked_Deallocation` helpers into
  `src/sdata_core-sorting.ads/.adb`, operating on the column map + a criteria
  array. The spilled-path SQL ORDER BY and the in-memory holder path both move.
  `Table.Sort` becomes a thin delegator. Note that the spilled path calls back
  into the backing store for the ORDER BY — pass the `Backing_Store` instance
  (or the relevant operation) in, keeping the no-`with Table` rule.
- Gate. `sdata`'s SORT/BY integration tests are the live coverage.

### M5 — `SData_Core.Grouping` extraction (BY-group, ~25 LOC)

- Move `Clear_By_Vars` / `Add_By_Var` / `By_Var_Count` / `By_Var_Name` /
  `In_Same_Group` + `Table_By_Vars` to `src/sdata_core-grouping.ads/.adb`.
  Resolve the value-read coupling per §4.4 (read cells via `Columns.Column_Maps`
  directly, with the map / cursor cache / BY-var list passed in — do not call
  back into `Table`). Consider (optional) using the `Get_Value_By_Col`
  cursor-cache form to also close Wozniak W5-after; if it adds risk, leave it
  and note it.
- Gate. Final state: `table.adb` is the facade + schema/values/output/filter
  glue; the three heavy clusters live in cohesive, independently-readable units.

## 6. Verification

- **Per milestone:** in-crate drivers (`tests/run-tests.sh`) + `sdata make
  check` + `data-vandal make check`, all green, before commit. CLAUDE.md's gate
  applies (every milestone touches `src/`).
- **Build stays clean:** 0 `-gnaty` hits across `sdata_core-*` (the B3 channel);
  new files inherit the same switch set, so they must conform (banners
  double-spaced, etc.).
- **Optional new coverage:** an in-crate `backing_store_tests.adb` or
  `columns_tests.adb` driving the extracted units directly (now that they are
  independently constructible) would harden M2/M3; add if cheap, list in
  `tests/README.md`.
- **Shim proof (M1):** the decisive signal that internal-only held is that both
  consumers compile and pass with **no source edits**.

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `Column_Type` shim subtly changes consumer resolution | M1 gate is "both consumers build untouched"; if the literal renames or `use type` misbehave, stop and reassess before M2. |
| `Column_Maps` re-keyed on `Column_Name` changes hash/equality behavior | `Hash`/`"="` defined on the upper-cased `Unbounded_String` payload — identical to today's `Ada.Strings.Hash` on the upper-cased `String`. Add a `columns_tests` round-trip if in doubt. |
| Moving the segment cache into `Backing_Store` perturbs the spill atomicity contract | Carry the contract comment verbatim; keep the clean-abort (skip in-memory `Clear` on `SQLite_Error`) exactly; M3 spot-check on a spilling dataset. |
| `Limited_Controlled` `Finalize` ordering for the owned `Backing_Store` instance | Keep `Store` a package-level singleton in `Table` (as today) so finalization timing is unchanged; do not make it a stack object. |
| Scope creep into K5 / W5 / public J1 | Explicit non-goals (§2). W5 is an *optional* M5 sub-step, gated on no added risk. |

## 8. Decision record

`docs/decisions/ADR-0007-decompose-table-package.md` records the decision, the
internal-only scope, the `Columns` + `Backing_Store` topology, the
`Column_Type` re-export shim, and the J1 public-tail deferral. Update the
`docs/decisions/README.md` index when it lands.

## 9. Handoff checklist for the implementing session

1. Read this spec and ADR-0007; skim `table.ads`/`table.adb` at current HEAD
   (line numbers here will have drifted — re-locate by name).
2. Implement **M1 only**, gate, open a PR, stop for review. Do **not** batch
   milestones — each is a reviewable unit.
3. Repeat M2…M5, each its own PR, each gated by both consumer suites.
4. No version bump unless a milestone is forced to touch a public signature
   (it should not — if one is, stop and raise it: the internal-only scope is
   broken and the decision needs revisiting).
5. After M2, mark J1-internal closed in the milestone `skeptic-after.md`; after
   M5, mark U1-after closed.
