# Table Decomposition Implementation Plan (audit U1 + J1-internal)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the `SData_Core.Table` god-package into `Columns` + `Backing_Store` + `Sorting` + `Grouping` behind a byte-for-byte unchanged public facade, and collapse the column-name representation sprawl into one private `Column_Name` type — all without any consumer source change or version bump.

**Architecture:** Five independently-shippable, behavior-preserving milestones (M1–M5), each its own PR. M1 relocates the data vocabulary into a new foundational `SData_Core.Columns` and proves a re-export shim keeps `Table`'s public API intact. M2 introduces the private `Column_Name` type. M3 extracts the SQLite spill kernel into an owned `Backing_Store` object (compiler-enforced encapsulation — it cannot `with Table`). M4/M5 peel off `Sorting` and `Grouping`.

**Tech Stack:** Ada 2012, Alire (`alr build`), GNAT `-gnaty` style set (two checks relaxed), `ada_sqlite3`, in-crate test drivers (`tests/run-tests.sh`) plus two consumer integration suites (`../sdata`, `../data-vandal`).

---

## Source documents (read first)

- Spec: `docs/specs/2026-06-12-table-decomposition-design.md`
- Decision: `docs/decisions/ADR-0007-decompose-table-package.md`
- Current code: `src/sdata_core-table.ads` (~250 LOC), `src/sdata_core-table.adb` (~1270 LOC)

## This is a refactor, not a feature — what "test" means here

There is **no classic red-green TDD** for these milestones: each one is *structure-only* and must produce **identical behavior**. The discipline is therefore inverted — the "test" is a behavior-preservation **gate** run after each change, and it must be green *before* commit. Every milestone uses the same gate:

```bash
# from sdata-core root
alr build 2>&1 | tee /tmp/m-build.log          # must be 0 errors AND 0 new -gnaty warnings (B3)
grep -i "warning" /tmp/m-build.log || echo "no warnings — good"
tests/run-tests.sh                              # in-crate drivers, all pass
( cd ../sdata && make check )                   # sdata integration + unit suites
( cd ../data-vandal && make check )             # data-vandal VANDALIZE suite
```

**Hard rule (per spec §9.4):** no milestone may touch a public signature in `table.ads`. If one seems to require it, **stop and raise it** — the internal-only scope is broken and ADR-0007 must be revisited. Do **not** bump `alire.toml`.

The single most important signal at M1 (and M4, which relocates more public-facing types) is that **both consumers build and pass with zero source edits** — that is the proof the facade held.

## Shared facts the plan relies on (verified against HEAD 2026-06-13)

- `Max_Name_Len : constant := 64;` and `Script_Error : exception;` live in the parent `src/sdata_core.ads` — visible to every child unit. Do not redeclare.
- `Column_Type` is **public** in `table.ads:25`; `Value_Vectors`, `Column`, `Column_Maps`, the cursor caches, all table state, and `Backing_Store` are in `table.ads`'s **private part** (`:160-248`).
- `Column.Name` (the padded `String (1 .. Max_Name_Len)` field) is **written but never read for logic** — names flow through the `Column_Maps` key and `Column_Order`. M2's padding removal is therefore safe.
- Internal sdata-core callers of `Table.Column_Type` / `Col_*`: `file_io.adb`, `file_io-csv.adb`, `file_io-odf.adb`, `file_io-ooxml.adb`, `file_io-helpers.{ads,adb}`, `variables.adb`. They reference them as `Table.Column_Type` / `Col_*` (some via `use SData_Core.Table`, some fully-qualified). **The M1 re-export shim covers all of these unchanged** — they are validated by `alr build` of sdata-core itself.
- `Table.Name_Vectors` is consumed by `commands.{ads,adb}` and `variables.{ads,adb}`. It is **out of scope** (J1 public tail) and **must stay in `Table` unchanged**. M2 introduces a *separate* `Columns.Column_Name_Vectors` for `Column_Order`; it must never alias or replace `Name_Vectors`.
- `Table.In_Same_Group (Idx1, Idx2)` is called by `evaluator-nav_fns.adb:102,134`. The 2-argument facade signature is locked; M5 delegates behind it.
- `Sort_Criteria` / `Sort_Direction` are public in `table.ads:86-92`; consumers build `Sort_Criteria_Array` aggregates (per spec). M4 relocates them with the same shim pattern as `Column_Type`.

---

## Task M1 — `SData_Core.Columns` foundation (relocate, no representation change)

**Files:**
- Create: `src/sdata_core-columns.ads`
- Modify: `src/sdata_core-table.ads` (public part: add shim; private part: delete moved decls, requalify)
- Modify: `src/sdata_core-table.adb` (add `with`/`use Columns`)

**Intent:** Move `Value_Vectors`, `Column_Type`, `Column`, `Column_Maps` into a new independent package. **Representation is unchanged** — `Column.Name` stays `String (1 .. Max_Name_Len)`, the map key stays `String`. Risk is isolated to "did the re-export shim hold."

- [ ] **Step 1: Create `src/sdata_core-columns.ads`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Columns holds the shared data vocabulary for the Table
--  subsystem: the column value type, the typed column record, and the
--  name-keyed column map.  It is foundational and independent -- it withs
--  nothing inside the Table cluster, so Backing_Store / Sorting / Grouping can
--  all build on it without a dependency cycle.

with Ada.Strings.Hash;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with SData_Core.Values; use SData_Core.Values;

package SData_Core.Columns is

   --  Kinds of data allowed in a column.
   type Column_Type is (Col_Numeric, Col_Integer, Col_String);

   --  Vector of values for a single column.
   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value);

   --  The internal representation of a column.
   type Column is record
      Name : String (1 .. Max_Name_Len); -- Padded name
      Typ  : Column_Type;      -- Enforced type
      Data : Value_Vectors.Vector; -- List of values (one per row)
      --  Output columns only: True when Typ was a placeholder inferred from a
      --  leading missing value of a derived column; cleared (and Typ set) on
      --  the first non-missing write.  See Add_Output_Column / Set_Output_Value*.
      Type_Is_Placeholder : Boolean := False;
   end record;

   --  Map from column name (String) to Column record.
   package Column_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String,
      Element_Type => Column,
      Hash => Ada.Strings.Hash,
      Equivalent_Keys => "=");

end SData_Core.Columns;
```

- [ ] **Step 2: Add the re-export shim to `table.ads`'s context clause + public part**

In `src/sdata_core-table.ads`, add to the context clause (after `with SData_Core.Values; use SData_Core.Values;`):

```ada
with SData_Core.Columns; use SData_Core.Columns;
```

Then **replace** the public declaration at `table.ads:24-25`:

```ada
   --  Kinds of data allowed in a column.
   type Column_Type is (Col_Numeric, Col_Integer, Col_String);
```

with the re-export shim:

```ada
   --  Kinds of data allowed in a column.  Relocated to SData_Core.Columns and
   --  re-exported here so the public API is byte-for-byte unchanged.  The
   --  subtype + literal renames alone are NOT enough: the enum's predefined "="
   --  moves to Columns, so a `use SData_Core.Table` (no `use type`) caller would
   --  lose direct visibility of it.  Re-export "=" too.  See ADR-0007 / spec 4.1.
   subtype Column_Type is SData_Core.Columns.Column_Type;
   function Col_Numeric return Column_Type renames SData_Core.Columns.Col_Numeric;
   function Col_Integer return Column_Type renames SData_Core.Columns.Col_Integer;
   function Col_String  return Column_Type renames SData_Core.Columns.Col_String;
   function "=" (Left, Right : Column_Type) return Boolean
     renames SData_Core.Columns."=";
```

> **Implemented 2026-06-13 (commit on `refactor/table-m1-columns`):** the `"="`
> re-export above was added after the bare subtype+renames shim broke
> `sdata`'s `tests/sdata_unit_test.adb:614/825/2371`. Only `"="` is needed
> (tree-wide grep shows no ordering/`/=` use on `Column_Type`). Both consumer
> suites pass with zero edits.

- [ ] **Step 3: Delete the moved declarations from `table.ads`'s private part and requalify the survivors**

In the private part of `table.ads`:

1. **Delete** the `Value_Vectors` package instantiation (`:161-162`).
2. **Delete** the `Column` record type (`:164-173`).
3. **Delete** the `Column_Maps` package instantiation (`:175-180`).
4. In the `Cursor_Vectors` instantiation (`:185-188`), the references `Column_Maps.Cursor` and `Column_Maps."="` now resolve through the `use SData_Core.Columns;` added in Step 2 — **no edit needed**, they bind to `Columns.Column_Maps`.
5. In the `Seg_Data_Maps` instantiation (`:221-226`), `Value_Vectors.Vector` and `Value_Vectors."="` likewise resolve via the `use` — **no edit needed**.

Everything else in the private part (`Data_Table : Column_Maps.Map;` etc.) binds to `Columns.Column_Maps` via the `use` clause.

> Note on homographs: the visible `subtype Column_Type` and the three literal renames are *immediately* declared in `Table`, so they **hide** the use-visible `Columns.Column_Type` / `Col_*`. No ambiguity. The non-redeclared names (`Column_Maps`, `Value_Vectors`, `Column`) come only from `Columns`.

- [ ] **Step 4: Confirm the body needs NO context-clause change**

Do **not** add `with SData_Core.Columns;` to `src/sdata_core-table.adb` — it is redundant (the `with`+`use` in `table.ads`'s context clause is inherited by the body) and draws style warnings. The body's unqualified `Column_Maps`, `Value_Vectors`, `Column` references bind to `Columns` via the inherited `use`; `Col_Numeric` / `Col_Integer` / `Col_String` bind to `Table`'s renames (immediately visible, hiding the use-visible ones) — semantically identical. Build to confirm; only if the compiler reports an unresolved name add the minimal qualification. *(Verified during M1: the body needed no edit.)*

- [ ] **Step 5: Build sdata-core and run in-crate drivers**

Run:
```bash
alr build 2>&1 | tee /tmp/m1-build.log
grep -i "warning" /tmp/m1-build.log || echo "no warnings — good"
tests/run-tests.sh
```
Expected: clean build, **zero** warnings, all five drivers pass.

- [ ] **Step 6: Run BOTH consumer suites with zero consumer edits (the decisive M1 gate)**

Run:
```bash
( cd ../sdata && make check )
( cd ../data-vandal && make check )
```
Expected: both green. **Do not edit either consumer.** If `Column_Type` resolution misbehaves, STOP and reassess before M2 (spec risk table, row 1).

- [ ] **Step 7: Commit**

```bash
git checkout -b refactor/table-m1-columns
git add src/sdata_core-columns.ads src/sdata_core-table.ads src/sdata_core-table.adb
git commit -m "refactor(table): extract SData_Core.Columns foundation (U1 M1)

Relocate Value_Vectors/Column_Type/Column/Column_Maps to a new
independent SData_Core.Columns; re-export Column_Type from Table via
subtype + literal renames so the public API is unchanged. No
representation change, no consumer edits, no version bump.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Then open a PR and **stop for review** (spec §9.2 — do not batch milestones).

---

## Task M2 — `Column_Name` private type (closes J1-internal)

**Files:**
- Modify: `src/sdata_core-columns.ads` (+ create `src/sdata_core-columns.adb`)
- Modify: `src/sdata_core-table.adb` (route every column-name conversion through `To_Column_Name` / `Image`)
- Modify: `src/sdata_core-table.ads` (private part: `Column_Order` / `Output_Column_Order` become `Column_Name_Vectors`)

**Intent:** Make `Column_Name` the single internal representation for `Column.Name`, the `Column_Maps` key, `Column_Order`, `Output_Column_Order`, and the BY-var list. Upper-casing happens in exactly one place (`To_Column_Name`). Public API still takes/returns `String`; the facade converts at the boundary. **`Table.Name_Vectors` is untouched.**

- [ ] **Step 1: Add `Column_Name` + a `Column_Name_Vectors` to `columns.ads`**

Add to the context clause of `src/sdata_core-columns.ads`:
```ada
with Ada.Strings.Unbounded;
with Ada.Containers;
```

Add to the visible part of `SData_Core.Columns` (before `Value_Vectors`):
```ada
   --  THE single internal column-name representation.  Always upper-cased;
   --  upper-casing happens only inside To_Column_Name (the one chokepoint).
   --  Closes the internal half of audit finding J1.  The public API still
   --  speaks String; the Table facade converts at its boundary with Image.
   type Column_Name is private;
   function To_Column_Name (S : String) return Column_Name;  -- upper-cases
   function Image (N : Column_Name) return String;           -- back to String
   function "=" (L, R : Column_Name) return Boolean;
   function Hash (N : Column_Name) return Ada.Containers.Hash_Type;

   --  Insertion-order list of column names (replaces the Unbounded_String
   --  Column_Order / Output_Column_Order vectors).  Distinct from
   --  Table.Name_Vectors, which is a consumer-facing public type and stays.
   package Column_Name_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Column_Name);
```

Add a `private` part to `columns.ads` (before `end SData_Core.Columns;`):
```ada
private

   type Column_Name is record
      Value : Ada.Strings.Unbounded.Unbounded_String;  -- always upper-cased
   end record;
```

Change `Column.Name` in the `Column` record from `String (1 .. Max_Name_Len)` to:
```ada
      Name : Column_Name;
```

Change the `Column_Maps` key from `String` to `Column_Name`, and its hash/equality to the new operations:
```ada
   package Column_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => Column_Name,
      Element_Type => Column,
      Hash => Hash,
      Equivalent_Keys => "=");
```

- [ ] **Step 2: Create `src/sdata_core-columns.adb`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body SData_Core.Columns is

   function To_Column_Name (S : String) return Column_Name is
   begin
      return (Value => To_Unbounded_String (Ada.Characters.Handling.To_Upper (S)));
   end To_Column_Name;

   function Image (N : Column_Name) return String is
   begin
      return To_String (N.Value);
   end Image;

   function "=" (L, R : Column_Name) return Boolean is
   begin
      return L.Value = R.Value;
   end "=";

   --  Hash the upper-cased payload as a plain String, so this is identical to
   --  the pre-J1 Ada.Strings.Hash on the upper-cased map key -- no behavior
   --  change to bucket distribution or equality (spec risk table, row 2).
   function Hash (N : Column_Name) return Ada.Containers.Hash_Type is
   begin
      return Ada.Strings.Hash (To_String (N.Value));
   end Hash;

end SData_Core.Columns;
```

- [ ] **Step 3: Convert `Column_Order` / `Output_Column_Order` in `table.ads`**

In the private part of `src/sdata_core-table.ads`, change both vectors from `Name_Vectors.Vector` to `Column_Name_Vectors.Vector`:
- `Output_Column_Order : Name_Vectors.Vector;` (`:196`) → `Output_Column_Order : Column_Name_Vectors.Vector;`
- `Column_Order : Name_Vectors.Vector;` (`:201`) → `Column_Order : Column_Name_Vectors.Vector;`

**Leave `Name_Vectors` (`:156`) exactly as it is** — it is public and consumer-facing.

- [ ] **Step 4: Route every column-name conversion in `table.adb` through `To_Column_Name` / `Image`**

Apply these conversions site-by-site. The rule: **map keys, `Column.Name`, the two order vectors, and `Table_By_Vars` are `Column_Name`; everything crossing the public boundary is `String`, converted with `To_Column_Name` (in) / `Image` (out).**

1. `Rebuild_Column_Cache` (`:41-49`): `Data_Table.Find (To_String (Column_Order.Element (I)))` → `Data_Table.Find (Column_Order.Element (I))` (element is already a `Column_Name`; no conversion).
2. `Rebuild_Output_Cache` (`:51-59`): same — drop the `To_String`, pass `Output_Column_Order.Element (I)` directly to `Output_Data_Table.Find`.
3. `Add_Column` (`:133-157`): replace the padded-name build and key/order inserts:
   ```ada
      Key : constant Column_Name := To_Column_Name (Name);
   begin
      if Data_Table.Contains (Key) then return; end if;
      New_Col.Name := Key;
      New_Col.Typ  := Col_Type;
      for I in 1 .. Table_Row_Count loop
         New_Col.Data.Append ((Kind => Val_Missing));
      end loop;
      Data_Table.Insert (Key, New_Col);
      Column_Order.Append (Key);
   ```
   (Remove the `Upper_Name : constant String := ... To_Upper ...` and the `New_Col.Name := (others => ' '); New_Col.Name (1 .. ...) := ...` lines.)
4. `Has_Column` (`:162-165`): `Data_Table.Contains (To_Column_Name (Name))`.
5. `Get_Column_Type` (`:170-188`): `Data_Table.Find (To_Column_Name (Name))`; the error string `... & Upper_Name` becomes `... & Ada.Characters.Handling.To_Upper (Name)`.
6. `Column_Name` function (`:201-204`): `return Image (Column_Order.Element (I));`.
7. `Get_Value_Upper` (`:245-264`): `Data_Table.Find (To_Column_Name (Upper_Name))`.
8. `Set_Value_Upper` (`:312-329`): `Data_Table.Find (To_Column_Name (Upper_Name))`.
9. `Coerce_Value` (`:274-310`): no key work — leave as is.
10. `Rename_Column` (`:334-401`): rebuild around `Column_Name`:
    - `Old_Key : constant Column_Name := To_Column_Name (Old_Name);`
    - `New_Key : constant Column_Name := To_Column_Name (New_Name);`
    - Replace `Data_Table.Find (Upper_Old)`/`Contains (Upper_New)` with the keys.
    - **Delete** the entire `New_Name : String (1 .. Max_Name_Len)` padding/truncation block (`:345,358-363`) — the field is now `Column_Name`.
    - In the `Insert` aggregate, `Name => New_Key`.
    - The `Column_Order` patch loop (`:391-396`): compare `Column_Order.Element (I) = Old_Key` and `Column_Order.Replace_Element (I, New_Key)` (both `Column_Name`; drop the `To_String`/`To_Unbounded_String`).
11. `Drop_Column` (`:406-420`): `Data_Table.Find (To_Column_Name (Name))`; in the order loop compare `Column_Order.Element (I) = To_Column_Name (Name)` (or reuse a local `Key`).
12. `Sort` spilled path (`:527-548`): `Name : constant String := Column_Name (I);` already returns `String` via the converted function (Step 4.6) — fine. `Get_Column_Type (Name)` fine. The criteria key for ORDER BY: `Sql_Id (Image (To_Column_Name (Criteria (I).Name (1 .. Criteria (I).Len))))`.
13. `Sort` in-memory path (`:618-660`): the per-criterion column lookup `Data_Table.Contains (Col_Name)` where `Col_Name` was `To_Upper(...)` → `Data_Table.Contains (To_Column_Name (Criteria (C).Name (1 .. Criteria (C).Len)))`; the `Get_Value_Upper (R, Col_Name)` keeps taking the upper `String` (define `Col_Name` as the `To_Upper` String for the value reads). The final reorder loop's `Current_Key : constant String := Column_Maps.Key (Pos);` → `Current_Key : constant Column_Name := Column_Maps.Key (Pos);` and `Get_Value_Upper (Indices.Ref (I), Image (Current_Key))`.
14. BY-vars (`Add_By_Var :713-716`, `By_Var_Name :723-726`, `In_Same_Group :731-746`): `Table_By_Vars` becomes `Column_Name_Vectors.Vector` (Step 5 below). `Add_By_Var` → `Table_By_Vars.Append (To_Column_Name (Name))`; `By_Var_Name` → `return Image (Table_By_Vars.Element (I))`; `In_Same_Group`'s `Name : constant String := To_String (V);` → `Name : constant String := Image (V);` (then `Get_Value_Upper (Idx, Name)` unchanged).
15. Output table — `Add_Output_Column` (`:809-828`): same treatment as `Add_Column` (Step 4.3): `Key := To_Column_Name (Name)`, `New_Col.Name := Key`, `Output_Data_Table.Insert (Key, New_Col)`, `Output_Column_Order.Append (Key)`, drop the padding.
16. `Set_Output_Value_Upper` (`:866-880`): `Output_Data_Table.Find (To_Column_Name (Upper_Name))`.
17. `Initialize_Output_Table` / `Commit_Output_Table`: `Output_Column_Order` and `Column_Order` are now `Column_Name_Vectors`; the assignment `Column_Order := Output_Column_Order;` (`:907`) stays valid (same vector type). No key edits.
18. `Get_Value_By_Col` (`:941-970`) / `Set_Output_Value_By_Col` (`:975-1002`): the `Column_Maps.Key (Cur)` results are now `Column_Name`; where they feed `Fetch_From_Disk (Row, Column_Maps.Key (Cur))` (a `String` parameter), wrap with `Image (...)`; where they feed `Coerce_Value (..., Column_Maps.Key (Cur))` (a `String` `Col_Name` parameter), wrap with `Image (...)`.
19. `Spill_Table_To_Disk` (`:1081-1162`): `Column_Maps.Key (Pos)` is now `Column_Name`. `Col_Names` currently stores `Unbounded_String`; populate it with `To_Unbounded_String (Image (Column_Maps.Key (Pos)))` so the rest of the SQL building (which already calls `To_String`) is unchanged.
20. `Fetch_From_Disk` (`:1177-1268`): keeps its `Col_Name : String` parameter and the `Seg_Cache` keyed by SQL column-name `String` — **no `Column_Name` change here** (it bridges SQLite text columns, not the in-memory map). Leave as is.

Add `with Ada.Characters.Handling;` is already present in the body (`:5`); `with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;` is reachable via the `.ads` context — confirm `Image`/`To_Column_Name` resolve via the `use SData_Core.Columns;` added in M1.

- [ ] **Step 5: Convert `Table_By_Vars` declaration**

In `table.adb:112`, change:
```ada
   Table_By_Vars : Name_Vectors.Vector;
```
to:
```ada
   Table_By_Vars : Column_Name_Vectors.Vector;
```

- [ ] **Step 6: Build, run in-crate drivers, gate both consumers**

```bash
alr build 2>&1 | tee /tmp/m2-build.log
grep -i "warning" /tmp/m2-build.log || echo "no warnings — good"
tests/run-tests.sh
( cd ../sdata && make check )
( cd ../data-vandal && make check )
```
Expected: all green. Pay attention to any SORT/BY test and any USE of a file with duplicate-after-upcasing column names — those exercise the hash/equality path (spec risk table, row 2).

- [ ] **Step 7: Mark J1-internal closed**

Per spec §9.5, update the audit tracking doc (`skeptic-after.md` if present in the repo or the relevant audit log) to mark **J1-internal closed**. If the file does not exist in sdata-core, note the closure in the M2 PR description instead.

- [ ] **Step 8: Commit**

```bash
git checkout -b refactor/table-m2-column-name
git add src/sdata_core-columns.ads src/sdata_core-columns.adb src/sdata_core-table.ads src/sdata_core-table.adb
git commit -m "refactor(table): single Column_Name internal type (U1 M2, closes J1-internal)

Introduce private Column_Name (upper-cased, Unbounded_String-backed) as
the one representation for Column.Name, the Column_Maps key, Column_Order,
Output_Column_Order, and the BY-var list. Upper-casing collapses to the
single To_Column_Name chokepoint; public API still speaks String. Hash/=
match the prior Ada.Strings.Hash on the upper-cased key, so behavior is
identical. Name_Vectors (public) untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Open PR, **stop for review**.

---

## Task M3 — `SData_Core.Backing_Store` extraction (the kernel, ~230 LOC)

**Files:**
- Create: `src/sdata_core-backing_store.ads`, `src/sdata_core-backing_store.adb`
- Modify: `src/sdata_core-columns.ads` / `.adb` (promote `Img`)
- Modify: `src/sdata_core-table.ads` (drop the moved private decls; hold one `Store` instance)
- Modify: `src/sdata_core-table.adb` (delegate to `Store`)

**Intent:** Move the SQLite spill kernel into an owned object that **cannot `with Table`** — encapsulation is compiler-enforced. `Table` keeps one package-level `Store` singleton (preserves finalization timing — spec risk table, row 4) and delegates.

- [ ] **Step 1: Promote `Img` to `SData_Core.Columns`**

`Img` (`table.adb:25-29`) formats the `[rows=…]` context for spill, sort, output-commit, and init errors — it is **not** backing-store-specific. Add to `columns.ads` visible part:
```ada
   --  Strip the leading space Integer'Image prepends for non-negative values
   --  so diagnostic strings read "rows=123" rather than "rows= 123".  Shared
   --  by Backing_Store, Sorting, and the Table facade for structured error
   --  context.
   function Img (N : Integer) return String;
```
Add to `columns.adb`:
```ada
   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;
```
Then **delete** the local `Img` from `table.adb:25-29`. Its existing call sites in `table.adb` (Sort error `:561-562`, Commit error `:928`) now resolve to `Columns.Img` via the `use SData_Core.Columns;` from M1.

- [ ] **Step 2: Create `src/sdata_core-backing_store.ads`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Backing_Store owns the SQLite disk-spill kernel: the DB handle,
--  the temp file, the input-segment prefetch cache, and segment bounds.  It is
--  parameterized on Columns.Column_Maps.Map -- it does NOT with SData_Core.Table,
--  so it cannot see Table's globals; the encapsulation is compiler-enforced
--  (ADR-0007).  A single instance is correct: one temp DB holds both the
--  "data" and "output_data" tables, and the read cache is input-only.

with Ada.Finalization;
with Ada.Strings.Unbounded;
with Ada_Sqlite3;
with SData_Core.Columns;
with SData_Core.Values;

package SData_Core.Backing_Store is

   type Backing_Store is limited private;

   --  Create the temp DB and register it for signal cleanup.  Idempotent:
   --  no-op if already active.
   procedure Initialize (Self : in out Backing_Store);

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
   --  A failed FIRST spill leaves Is_Active = True (set by Initialize before
   --  the write).  Benign and intentionally NOT unwound: reads still hit the
   --  in-memory segment, Initialize is idempotent so no temp file leaks, the
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
```

> The `with Ada.Containers.Indefinite_Hashed_Maps;` and `with Ada.Strings.Hash;` needed by the private `Seg_Data_Maps` go in the context clause too. The dropped `Row_Limit` field (`table.ads:239`) was dead — do not carry it.

- [ ] **Step 3: Create `src/sdata_core-backing_store.adb`**

Move the bodies of `Sql_Id` (`table.adb:64-77`), `Initialize_Backing_Store` (`:1017-1044`), `Spill_Table_To_Disk` (`:1081-1162`), and `Fetch_From_Disk` (`:1177-1268`), plus the `Finalize` for the store (`:82-105`) and `Clear_Fetch_Cache` (`:31-36`), into the new body, rewired onto `Self`:

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Config;
with SData_Core.Signals;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Backing_Store is

   use type Ada.Containers.Count_Type;

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

   function Is_Active (Self : Backing_Store) return Boolean is
   begin
      return Self.Is_Active;
   end Is_Active;

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

   procedure Initialize (Self : in out Backing_Store) is
      FD : GNAT.OS_Lib.File_Descriptor;
      Temp_Name : GNAT.Strings.String_Access;
   begin
      if Self.Is_Active then return; end if;
      GNAT.OS_Lib.Create_Temp_File (FD, Temp_Name);
      GNAT.OS_Lib.Close (FD);
      Self.Temp_Path := To_Unbounded_String (Temp_Name.all);
      Self.DB := new Ada_Sqlite3.Database'(Ada_Sqlite3.Open (Temp_Name.all));
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
   end Initialize;

   procedure Close (Self : in out Backing_Store) is
      Success : Boolean;
   begin
      if not Self.Is_Active then return; end if;
      Self.Is_Active := False;
      SData_Core.Signals.Clear_Cleanup_Path;
      declare
         Path : constant String := To_String (Self.Temp_Path);
      begin
         --  Avoid freeing Self.DB: it triggers a double-finalization crash in
         --  ada_sqlite3 0.1.1 (the only published version; upstream
         --  github.com/gtnoble/ada-sqlite3 @ 2edbceb).  The OS reclaims the
         --  memory; we only remove the file.  REVISIT when bumping
         --  ada_sqlite3 past 0.1.1 (see alire.toml).
         GNAT.OS_Lib.Delete_File (Path, Success);
      end;
      Self.Seg_Cache.Clear;
      Self.Seg_Start := 0;
      Self.Seg_End   := 0;
   end Close;

   overriding procedure Finalize (Self : in out Backing_Store) is
   begin
      Close (Self);
   end Finalize;

   procedure Spill (Self  : in out Backing_Store;
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
      if T.Is_Empty then return; end if;
      Clear_Cache (Self);
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
      Initialize (Self);

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

      SQL := To_Unbounded_String
        ("INSERT OR REPLACE INTO [" & Name & "] (record_id");
      for N of Col_Names loop Append (SQL, ", " & Sql_Id (To_String (N))); end loop;
      Append (SQL, ") VALUES (?");
      for I in 1 .. Natural (Col_Names.Length) loop Append (SQL, ", ?"); end loop;
      Append (SQL, ")");

      declare
         Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare (To_String (SQL));
      begin
         Self.DB.Execute ("BEGIN");
         for R in 1 .. Memory_Rows loop
            Stmt.Reset;
            Stmt.Clear_Bindings;
            Stmt.Bind_Int (1, Start + R - 1);
            for C in 1 .. Natural (Col_Names.Length) loop
               declare
                  Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
                     Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
                  Val : constant Value := Ref.Element.all.Data.Element (R);
               begin
                  case Val.Kind is
                     when Val_Numeric => Stmt.Bind_Double (C + 1, Val.Num_Val);
                     when Val_Integer => Stmt.Bind_Int (C + 1, Val.Int_Val);
                     when Val_String  => Stmt.Bind_Text (C + 1, To_String (Val.Str_Val));
                     when Val_Missing => Stmt.Bind_Null (C + 1);
                  end case;
               end;
            end loop;
            Stmt.Step;
         end loop;
         Self.DB.Execute ("COMMIT");
      end;

      for Pos in T.Iterate loop T.Reference (Pos).Element.all.Data.Clear; end loop;
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not write dataset to disk (disk full?)"
            & " [table=" & Name
            & ", rows=" & Columns.Img (Memory_Rows)
            & ", segment_start=" & Columns.Img (Start) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Spill;

   function Fetch (Self      : in out Backing_Store;
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
            Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare
               ("SELECT * FROM [data] WHERE record_id >= ? AND record_id <= ?" &
                " ORDER BY record_id");
            Num_Cols : Integer;
         begin
            Stmt.Bind_Int (1, S_Start);
            Stmt.Bind_Int (2, S_End);
            Self.Seg_Cache.Clear;
            Num_Cols := Stmt.Column_Count - 1;  --  exclude record_id at index 0
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
                        Val := (Kind => Val_Numeric, Num_Val => Stmt.Column_Double (I));
                     elsif Typ = Ada_Sqlite3.Integer_Type then
                        Val := (Kind => Val_Integer, Int_Val => Stmt.Column_Int (I));
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
   end Fetch;

end SData_Core.Backing_Store;
```

> Add `with Ada.Containers.Vectors;` to the body context clause for the local `Name_Vecs`/`Cursor_Vecs`. The literal `Col_Numeric`/`Col_Integer` here bind to `Columns` via `use SData_Core.Columns;` (no Table shim in scope, which is correct — this unit must not see Table).

- [ ] **Step 4: Strip the moved decls from `table.ads`'s private part**

In `src/sdata_core-table.ads`:
1. Add `with SData_Core.Backing_Store;` to the context clause.
2. **Delete** the `Seg_Data_Maps` package + `Seg_Cache`/`Seg_Start`/`Seg_End` (`:216-229`).
3. **Delete** the `Database_Access` type, the `Backing_Store` record + its `overriding procedure Finalize`, and `Store : Backing_Store;` (`:231-243`) — **replace** with:
   ```ada
   --  Single owned spill kernel.  Package-level singleton (not a stack object)
   --  so finalization timing is unchanged (spec risk table, row 4).
   Store : SData_Core.Backing_Store.Backing_Store;
   ```
4. **Delete** the three storage-management forward decls `Initialize_Backing_Store` / `Spill_To_Disk` / `Fetch_From_Disk` (`:245-248`). Keep `Spill_To_Disk` / `Spill_Output_To_Disk` only if still used internally (they become trivial wrappers in the body — see Step 5; their forward decls at `table.adb:61-62` stay in the body).
5. Remove `with Ada.Finalization;`, `with Ada.Strings.Hash;`, `with Ada_Sqlite3;` from `table.ads` **only if** nothing else in `table.ads` still needs them. (`Ada.Strings.Hash` and `Ada_Sqlite3` were only for the moved decls; `Ada.Finalization` was for the moved `Backing_Store` and the Sort holders live in the *body*. Verify with a build — leave any that the compiler still demands.)

- [ ] **Step 5: Delegate from `table.adb`**

1. **Delete** the moved bodies: `Clear_Fetch_Cache` (`:31-36`), `Sql_Id` (`:64-77`), the store `Finalize` (`:82-105`), `Initialize_Backing_Store` (`:1017-1044`), `Spill_Table_To_Disk` (`:1081-1162`), `Fetch_From_Disk` (`:1177-1268`).
2. Replace `Spill_To_Disk` / `Spill_Output_To_Disk` (`:1164-1172`) with delegators:
   ```ada
   procedure Spill_To_Disk is
   begin
      Store.Spill (Data_Table, "data", Current_Segment_Start);
   end Spill_To_Disk;

   procedure Spill_Output_To_Disk is
   begin
      Store.Spill (Output_Data_Table, "output_data", Output_Segment_Start);
   end Spill_Output_To_Disk;
   ```
3. `Clear` (`:117-128`): `Finalize (Store);` → `Store.Close;`.
4. Every `Clear_Fetch_Cache;` call (`Add_Column :155`, `Sort :514`, `Commit_Output_Table :890`) → `Store.Clear_Cache;`.
5. `Get_Value_Upper` (`:258-259`): `elsif Store.Is_Active then return Fetch_From_Disk (Row, Upper_Name);` → `elsif Store.Is_Active then return Store.Fetch (Row, Upper_Name, Data_Table, Table_Row_Count);`.
6. `Get_Value_By_Col` (`:964-965`): `elsif Store.Is_Active then return Fetch_From_Disk (Row, Column_Maps.Key (Cur));` → `elsif Store.Is_Active then return Store.Fetch (Row, Image (Column_Maps.Key (Cur)), Data_Table, Table_Row_Count);`.
7. `Get_Backing_Store_Path` (`:751-758`): collapse to `return Store.Path;`.
8. Sort spilled path: `Spill_To_Disk;` (`:517`) stays (it now delegates). Every `Store.DB.Execute (...)` (`:552-556`) → `Store.Execute (...)`.
9. `Initialize_Output_Table` (`:803-805`): `Store.DB.Execute ("DROP TABLE IF EXISTS output_data");` → `Store.Execute (...)` (keep the `if Store.Is_Active then` guard).
10. `Commit_Output_Table`: every `Store.DB.Execute (...)` (`:902-903,914,917`) → `Store.Execute (...)`.
11. Remove now-unused `with`s from the body (`Ada_Sqlite3`, `GNAT.OS_Lib`, `GNAT.Strings`, `Ada.Unchecked_Deallocation` if the only remaining users are the Sort holders — those stay, so keep `Ada.Unchecked_Deallocation`). Build will flag unused `with`s as `-gnaty` warnings — let the build tell you which to drop.

- [ ] **Step 6: Build, drivers, gate both consumers + spill spot-check**

```bash
alr build 2>&1 | tee /tmp/m3-build.log
grep -i "warning" /tmp/m3-build.log || echo "no warnings — good"
tests/run-tests.sh
( cd ../sdata && make check )
( cd ../data-vandal && make check )
```
Then a **spill spot-check** (spec M3 gate): drive a dataset large enough to spill with a small `Max_Table_Cells` (sdata flag `-m`/`--maxcells`, see `sdata --help`) through `../sdata`, confirm read-back values are identical and the temp file is deleted on normal exit and on SIGINT. The sdata suite's spill/large-dataset tests cover most of this; run them explicitly if tagged.

- [ ] **Step 7: Commit**

```bash
git checkout -b refactor/table-m3-backing-store
git add src/sdata_core-backing_store.ads src/sdata_core-backing_store.adb \
        src/sdata_core-columns.ads src/sdata_core-columns.adb \
        src/sdata_core-table.ads src/sdata_core-table.adb
git commit -m "refactor(table): extract SData_Core.Backing_Store spill kernel (U1 M3)

Move the SQLite spill/fetch/init kernel + segment cache into an owned
Backing_Store object parameterized on Columns.Column_Maps.Map. It cannot
with Table, so the encapsulation is compiler-enforced. Table holds one
package-level Store singleton (finalization timing unchanged) and
delegates. Img promoted to Columns. Behavior identical; atomicity /
clean-abort contract carried verbatim.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Open PR, **stop for review**.

---

## Task M4 — `SData_Core.Sorting` extraction (~175 LOC)

**Files:**
- Modify: `src/sdata_core-columns.ads` (relocate `Sort_Direction` / `Sort_Criteria` / `Sort_Criteria_Array`)
- Modify: `src/sdata_core-table.ads` (re-export shim; drop the moved types)
- Create: `src/sdata_core-sorting.ads`, `src/sdata_core-sorting.adb`
- Modify: `src/sdata_core-table.adb` (`Sort` becomes a thin delegator; move holder types out)

**Intent:** Relocate the public sort types to `Columns` with the same shim pattern as `Column_Type`, then move the 157-LOC `Sort` (both the spilled SQL path and the in-memory merge-sort) into an independent unit operating on the column map + criteria + the `Store`.

> **Contingency (spec §4.4):** the recommended path is the `Columns` relocation + re-export shim. If the `Sort_Criteria` / `Ascending` / `Descending` shim fails the consumer build (e.g. an aggregate or `use type` that does not resolve), fall back to making `SData_Core.Sorting` a **private child of `Table`** (`package SData_Core.Table.Sorting`), which sees the public types + private state directly — trading compiler-enforced isolation for simplicity. If you take the fallback, record it in this PR and in ADR-0007 "Consequences." The facade and public API are unaffected either way.

- [ ] **Step 1: Relocate sort types to `Columns`**

Add to `columns.ads` visible part (after `Column_Maps`):
```ada
   --  Sorting support.  Relocated here (from Table) so SData_Core.Sorting can
   --  build on it without a with-cycle; Table re-exports unchanged (sec 4.4).
   type Sort_Direction is (Ascending, Descending);
   type Sort_Criteria is record
      Name : String (1 .. Max_Name_Len);
      Len  : Natural;
      Dir  : Sort_Direction;
   end record;
   type Sort_Criteria_Array is array (Positive range <>) of Sort_Criteria;
```

- [ ] **Step 2: Re-export from `table.ads`**

**Replace** the sort-type block at `table.ads:85-92`:
```ada
   --  Sorting support
   type Sort_Direction is (Ascending, Descending);
   type Sort_Criteria is record
      Name : String (1 .. Max_Name_Len);
      Len  : Natural;
      Dir  : Sort_Direction;
   end record;
   type Sort_Criteria_Array is array (Positive range <>) of Sort_Criteria;
```
with:
```ada
   --  Sorting support.  Relocated to SData_Core.Columns and re-exported here so
   --  consumer aggregates (Sort_Criteria_Array) and `use type` keep compiling
   --  byte-for-byte (sec 4.4, same shim pattern as Column_Type).
   subtype Sort_Direction is SData_Core.Columns.Sort_Direction;
   function Ascending  return Sort_Direction renames SData_Core.Columns.Ascending;
   function Descending return Sort_Direction renames SData_Core.Columns.Descending;
   function "=" (Left, Right : Sort_Direction) return Boolean
     renames SData_Core.Columns."=";   -- same correction as Column_Type (M1)
   subtype Sort_Criteria       is SData_Core.Columns.Sort_Criteria;
   subtype Sort_Criteria_Array is SData_Core.Columns.Sort_Criteria_Array;
```

> **Apply the M1 operator-re-export lesson:** before relying on the block above,
> grep both consumers for `Sort_Direction` comparisons under a plain `use
> SData_Core.Table` (e.g. `Dir = Ascending`) and for any `Sort_Criteria` `"="`
> use. Re-export each operator actually used — at minimum `"=" (Sort_Direction)`
> as shown — or the M4 consumer build breaks exactly as the bare M1 shim did. Add
> only the operators the grep/build demand (unused renames draw `-gnaty` warnings).

- [ ] **Step 3: Create `src/sdata_core-sorting.ads`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Sorting holds the table sort: the spilled-dataset SQL ORDER BY
--  path and the in-memory stable merge-sort.  It operates on the column map +
--  insertion order + criteria, and is handed the Backing_Store instance for
--  the spilled path -- it does NOT with Table (no cycle; sec 4.4 recommended).

with SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Sorting is

   --  Reorder T in place per Criteria.  Stable (record_id / original-index
   --  tie-break).  When Store.Is_Active the sort runs in SQLite; otherwise
   --  in memory.  Column_Order gives user-visible column sequence for the
   --  spilled CREATE/INSERT; Segment_Start is the live segment's first row.
   procedure Sort
     (T             : in out Columns.Column_Maps.Map;
      Column_Order  : Columns.Column_Name_Vectors.Vector;
      Criteria      : Columns.Sort_Criteria_Array;
      Row_Count     : Natural;
      Segment_Start : Positive;
      Store         : in out Backing_Store.Backing_Store);

end SData_Core.Sorting;
```

- [ ] **Step 4: Create `src/sdata_core-sorting.adb`**

Move the holder types (`table.adb:468-500`) and the `Sort` body (`:505-662`) here, rewired. Concrete shape:

```ada
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

   use type Ada.Containers.Count_Type;

   --  Sql_Id is needed for the spilled ORDER BY.  Backing_Store keeps its own
   --  copy private; duplicate the 9-line quoter here rather than widen the
   --  Backing_Store API for one caller.  (If a third caller appears, promote
   --  it to Columns.)
   function Sql_Id (Name : String) return String is
      Buf : String (1 .. Name'Length * 2);
      Len : Natural := 0;
   begin
      for C of Name loop
         Len := Len + 1;
         Buf (Len) := C;
         if C = ']' then Len := Len + 1; Buf (Len) := ']'; end if;
      end loop;
      return "[" & Buf (1 .. Len) & "]";
   end Sql_Id;

   --  ... move Sort_Key_Row / Sort_Key_Holder / Sort_Indices_* holder types
   --      and their Finalize bodies here verbatim from table.adb:468-500 ...

   procedure Sort
     (T             : in out Columns.Column_Maps.Map;
      Column_Order  : Columns.Column_Name_Vectors.Vector;
      Criteria      : Columns.Sort_Criteria_Array;
      Row_Count     : Natural;
      Segment_Start : Positive;
      Store         : in out Backing_Store.Backing_Store)
   is
      N : constant Natural := Row_Count;

      --  Local value reader: the in-memory path runs only when the store is
      --  NOT active, so Segment_Start = 1 and the cell is Data.Element (Row).
      --  Mirrors the old Get_Value_Upper for the not-spilled case exactly.
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
      SData_Core.IO.Show_Progress ("SORT", N, Final => True);
      Store.Clear_Cache;

      if Store.Is_Active (Store) then
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
                  Typ   : constant Column_Type :=
                     T.Constant_Reference (T.Find (Key)).Element.all.Typ;
                  SQL_T : constant String := (if Typ = Col_Numeric then "REAL"
                                              elsif Typ = Col_Integer then "INTEGER"
                                              else "TEXT");
               begin
                  Append (Cols_CSV, Sql_Id (Name));
                  Append (Col_Def,  Sql_Id (Name) & " " & SQL_T);
                  if I < Col_N then Append (Cols_CSV, ", "); Append (Col_Def, ", "); end if;
               end;
            end loop;
            for I in Criteria'Range loop
               Append (OrderBy, Sql_Id (Ada.Characters.Handling.To_Upper
                       (Criteria (I).Name (1 .. Criteria (I).Len))));
               if Criteria (I).Dir = Descending then Append (OrderBy, " DESC"); end if;
               if I < Criteria'Last then Append (OrderBy, ", "); end if;
            end loop;
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

      --  ... in-memory path: move table.adb:568-661 verbatim, but replace
      --      every `Get_Value_Upper (R, Col_Name)` / `Get_Value_Upper
      --      (Indices.Ref (I), Current_Key)` with `Cell (R, To_Column_Name
      --      (...))` / `Cell (Indices.Ref (I), Current_Key)`, and the column
      --      iteration's `Current_Key : constant String := Column_Maps.Key
      --      (Pos);` with `Current_Key : constant Columns.Column_Name :=
      --      Columns.Column_Maps.Key (Pos);`.  Data_Table -> T throughout.
   end Sort;

end SData_Core.Sorting;
```

> When transcribing the in-memory path, the per-criterion key lookup uses `To_Column_Name (Criteria (C).Name (1 .. Criteria (C).Len))` for `T.Contains` and `Cell`. `Ada.Containers.Vectors` is reachable via the holder-array declarations; add `with Ada.Containers.Vectors;` if needed.

- [ ] **Step 5: Make `Table.Sort` a delegator + remove the moved code**

In `src/sdata_core-table.ads`, add `with SData_Core.Sorting;` to the context clause.

In `src/sdata_core-table.adb`:
1. **Delete** the holder types + their `Finalize`s (`:454-500`).
2. **Replace** the entire `Sort` body (`:502-662`) with:
   ```ada
   procedure Sort (Criteria : Sort_Criteria_Array) is
   begin
      Sorting.Sort (Data_Table, Column_Order, Criteria,
                    Table_Row_Count, Current_Segment_Start, Store);
   end Sort;
   ```
   (`Criteria` is `Table.Sort_Criteria_Array`, a subtype of `Columns.Sort_Criteria_Array`, so it passes directly.)
3. Drop `with Ada.Unchecked_Deallocation;` from the body **only if** `Clear_Index_Map`'s local `Free` is the sole remaining user — it is (`:695`), so **keep** the `with`.

- [ ] **Step 6: Build, drivers, gate both consumers**

```bash
alr build 2>&1 | tee /tmp/m4-build.log
grep -i "warning" /tmp/m4-build.log || echo "no warnings — good"
tests/run-tests.sh
( cd ../sdata && make check )      # sdata's SORT/BY integration tests are the live coverage
( cd ../data-vandal && make check )
```
Expected: all green, **consumers untouched**. If the `Sort_Criteria` shim breaks a consumer, take the private-child contingency (see this task's note) and re-run.

- [ ] **Step 7: Commit**

```bash
git checkout -b refactor/table-m4-sorting
git add src/sdata_core-sorting.ads src/sdata_core-sorting.adb \
        src/sdata_core-columns.ads src/sdata_core-table.ads src/sdata_core-table.adb
git commit -m "refactor(table): extract SData_Core.Sorting (U1 M4)

Relocate Sort_Criteria/Sort_Direction to Columns + Table re-export shim;
move the spilled SQL ORDER BY path and the in-memory stable merge-sort
into an independent SData_Core.Sorting operating on the column map +
criteria + Backing_Store. Table.Sort is now a thin delegator. Behavior
identical; consumers untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Open PR, **stop for review**.

---

## Task M5 — `SData_Core.Grouping` extraction (BY-group, ~25 LOC)

**Files:**
- Create: `src/sdata_core-grouping.ads`, `src/sdata_core-grouping.adb`
- Modify: `src/sdata_core-table.ads` (drop `Table_By_Vars`; add `with`)
- Modify: `src/sdata_core-table.adb` (BY-var ops become delegators)

**Intent:** Move `Clear_By_Vars` / `Add_By_Var` / `By_Var_Count` / `By_Var_Name` / `In_Same_Group` + `Table_By_Vars` into `SData_Core.Grouping`. The cell reads in `In_Same_Group` go through `Columns.Column_Maps` + the `Store` directly — **no callback into `Table`** (spec §4.4). The public `Table.In_Same_Group (Idx1, Idx2)` facade signature is preserved (called by `evaluator-nav_fns.adb`).

- [ ] **Step 1: Create `src/sdata_core-grouping.ads`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Grouping holds the BY-group state: the active BY-variable names
--  and the same-group test.  In_Same_Group reads cell values via
--  Columns.Column_Maps + the Backing_Store directly -- it does NOT with Table
--  (sec 4.4).  The BY-var list is package-level state, mirroring the prior
--  Table_By_Vars singleton.

with SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Grouping is

   procedure Clear_By_Vars;
   procedure Add_By_Var (Name : String);
   function  By_Var_Count return Natural;
   function  By_Var_Name (I : Positive) return String;

   --  True iff rows Idx1 and Idx2 share all BY-var values (empty BY => always
   --  True; equal indices => True; out-of-range => False).  Reads cells from T
   --  (live segment) or Store (spilled), exactly as the old Get_Value_Upper.
   function In_Same_Group
     (Idx1, Idx2    : Positive;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Boolean;

end SData_Core.Grouping;
```

- [ ] **Step 2: Create `src/sdata_core-grouping.adb`**

```ada
--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;

package body SData_Core.Grouping is

   Table_By_Vars : Columns.Column_Name_Vectors.Vector;

   --  Read one cell, live-segment-or-spilled, mirroring the old
   --  Table.Get_Value_Upper exactly.
   function Cell
     (Row           : Positive;
      Key           : Columns.Column_Name;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Value
   is
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
         elsif Store.Is_Active (Store) then
            return Store.Fetch (Row, Columns.Image (Key), T, Row_Count);
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Cell;

   procedure Clear_By_Vars is
   begin
      Table_By_Vars.Clear;
   end Clear_By_Vars;

   procedure Add_By_Var (Name : String) is
   begin
      Table_By_Vars.Append (Columns.To_Column_Name (Name));
   end Add_By_Var;

   function By_Var_Count return Natural is
   begin
      return Natural (Table_By_Vars.Length);
   end By_Var_Count;

   function By_Var_Name (I : Positive) return String is
   begin
      return Columns.Image (Table_By_Vars.Element (I));
   end By_Var_Name;

   function In_Same_Group
     (Idx1, Idx2    : Positive;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Boolean is
   begin
      if Table_By_Vars.Is_Empty then return True; end if;
      if Idx1 = Idx2 then return True; end if;
      if Idx1 > Row_Count or else Idx2 > Row_Count then return False; end if;
      for V of Table_By_Vars loop
         declare
            Val1 : constant Value := Cell (Idx1, V, T, Store, Segment_Start, Row_Count);
            Val2 : constant Value := Cell (Idx2, V, T, Store, Segment_Start, Row_Count);
         begin
            if not (Val1 = Val2) then return False; end if;
         end;
      end loop;
      return True;
   end In_Same_Group;

end SData_Core.Grouping;
```

> This **fixes a latent correctness gap**: the old `In_Same_Group` (`table.adb:731-746`) read via `Get_Value_Upper`, but the `Cell` helper here keeps the spilled-fetch branch, so behavior on a spilled BY-grouped table is preserved. Confirm the sdata BY-group + large-dataset tests still pass (Step 5).

- [ ] **Step 3: Drop `Table_By_Vars` + the moved bodies from `table.adb`**

In `src/sdata_core-table.adb`:
1. **Delete** `Table_By_Vars : Column_Name_Vectors.Vector;` (`:112`, from M2).
2. **Replace** the five BY-var bodies (`:705-746`) with delegators:
   ```ada
   procedure Clear_By_Vars is
   begin
      Grouping.Clear_By_Vars;
   end Clear_By_Vars;

   procedure Add_By_Var (Name : String) is
   begin
      Grouping.Add_By_Var (Name);
   end Add_By_Var;

   function By_Var_Count return Natural is
   begin
      return Grouping.By_Var_Count;
   end By_Var_Count;

   function By_Var_Name (I : Positive) return String is
   begin
      return Grouping.By_Var_Name (I);
   end By_Var_Name;

   function In_Same_Group (Idx1, Idx2 : Positive) return Boolean is
   begin
      return Grouping.In_Same_Group
        (Idx1, Idx2, Data_Table, Store, Current_Segment_Start, Table_Row_Count);
   end In_Same_Group;
   ```

- [ ] **Step 4: Add the `with` to `table.ads`**

In `src/sdata_core-table.ads`, add `with SData_Core.Grouping;` to the context clause.

- [ ] **Step 5: Build, drivers, gate both consumers**

```bash
alr build 2>&1 | tee /tmp/m5-build.log
grep -i "warning" /tmp/m5-build.log || echo "no warnings — good"
tests/run-tests.sh
( cd ../sdata && make check )      # BY-group tests are the live coverage; run spilled-BY if tagged
( cd ../data-vandal && make check )
```
Expected: all green, consumers untouched.

> **W5 (optional, spec M5):** reusing the `Get_Value_By_Col` cursor-cache form in `In_Same_Group` to also close Wozniak W5-after is **out of scope unless it adds no risk**. The cursor cache lives in `Table`'s private state, not `Grouping` — wiring it through would mean passing the cache in, which adds surface for marginal gain. **Leave it; note in the PR that W5 remains open.**

- [ ] **Step 6: Mark U1-after closed**

Per spec §9.5, mark **U1-after closed** in the audit tracking doc (or note it in the PR if the file lives only in the audit context). `table.adb` is now the facade + schema/values/output/filter glue; the three heavy clusters live in `Backing_Store`, `Sorting`, `Grouping`.

- [ ] **Step 7: Commit**

```bash
git checkout -b refactor/table-m5-grouping
git add src/sdata_core-grouping.ads src/sdata_core-grouping.adb \
        src/sdata_core-table.ads src/sdata_core-table.adb
git commit -m "refactor(table): extract SData_Core.Grouping (U1 M5, closes U1-after)

Move the BY-group state + In_Same_Group into SData_Core.Grouping, reading
cells via Columns.Column_Maps + Backing_Store directly (no with Table).
Table's public In_Same_Group (Idx1, Idx2) facade is preserved. table.adb
is now a facade over Columns/Backing_Store/Sorting/Grouping.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Open PR, **stop for review**.

---

## Optional hardening (spec §6, add if cheap)

After M2/M3 land, an in-crate `tests/columns_tests.adb` and/or `tests/backing_store_tests.adb` driving the now-independently-constructible units directly would harden the round-trip behavior. If added:
1. Write the driver in the same inline-assertion style as `tests/values_tests.adb` (a plain main, `Assert (Cond, Name)`, exits non-zero on failure).
2. Register it in `tests/sdata_core_tests.gpr`'s `for Main use (...)` list.
3. Add it to the loop in `tests/run-tests.sh`.
4. Document it in the `tests/README.md` coverage table.

Suggested `columns_tests` assertions: `Image (To_Column_Name ("abc")) = "ABC"`; `To_Column_Name ("Ab") = To_Column_Name ("aB")`; `Hash (To_Column_Name ("X")) = Ada.Strings.Hash ("X")`; a `Column_Maps` insert-under-mixed-case / find-under-other-case round-trip.

---

## Final self-review (done while writing — recorded here)

- **Spec coverage:** M1↔spec M1 (§5), M2↔M2, M3↔M3, M4↔M4, M5↔M5; §4.1 shim (M1 Step 2), §4.2 `Column_Name` (M2), §4.3 `Backing_Store` interface + `Img` promotion (M3 Steps 1-3), §4.4 Sorting/Grouping coupling resolutions + contingencies (M4 note, M5 §4.4 reads), §6 verification gate (every milestone Step "build/drivers/consumers"), §6 optional drivers (Optional hardening), §7 risks (M1 Step 6 shim, M2 Step 6 hash, M3 Step 6 spill spot-check + singleton note in M3 Step 4), §9 handoff (one PR per milestone, stop-for-review, no version bump, J1/U1 closure steps).
- **Out-of-scope guards honored:** `Name_Vectors` stays in `Table` (M2 Step 3 explicit); public `Sort_Criteria.Name+Len` representation unchanged (M4 relocates the type verbatim, not its rep); K5 LRU and W5 left as documented gaps (M5 Step 5 note).
- **Type consistency:** `To_Column_Name`/`Image`/`Hash`/`"="` signatures identical across M2 declaration and all M3/M4/M5 uses; `Column_Name_Vectors` introduced in M2 and consumed in M4 (`Column_Order` parameter) and M5 (`Table_By_Vars`); `Backing_Store` ops (`Initialize`/`Spill`/`Fetch`/`Path`/`Is_Active`/`Clear_Cache`/`Execute`/`Close`) defined in M3 and called consistently in M3 delegation, M4 `Sorting`, M5 `Grouping`.
```
