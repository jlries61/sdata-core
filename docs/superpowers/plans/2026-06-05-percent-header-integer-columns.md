# `%`-header → integer columns on load — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the CSV, ODF, and OOXML loaders type a column `Col_Integer` when its header name ends in `%`, mirroring the existing `$`→`Col_String` rule.

**Architecture:** Suffix-only, authoritative type inference at load. CSV handles the suffix inline in `Infer_Column_Types`; ODF/OOXML share a helper (generalized from `Apply_Dollar_Override`). Per-cell: integers store as `Val_Integer` (via the existing `Coerce_Value`), non-integer numerics truncate toward zero **with a warning**, non-numerics warn + store missing. No table or writer change.

**Tech Stack:** Ada 2012; Alire path-pinned `sdata-core` consumed by `sdata` and `data-vandal`. Loader code lives in `sdata-core`. **All new tests live in `data-vandal`**, whose harness diffs a produced CSV against a golden (ideal for this feature); `data-vandal` `USE` reads CSV/ODF/OOXML and `SAVE` writes CSV, so even the spreadsheet readers are testable through a CSV golden.

**Spec:** `docs/superpowers/specs/2026-06-05-percent-header-integer-columns-design.md`

---

## Orientation (read before starting)

- **Three sibling repos, path-pinned:** `~/Develop/sdata-core` (library; all code changes here), `~/Develop/data-vandal` (consumer; **all new tests here**), `~/Develop/sdata` (consumer; run for regression only). Editing `sdata-core/src` is picked up directly by both consumers' `make check`.
- **data-vandal test harness** (the one we use): for each `tests/<base>.cmd`, runs `bin/data-vandal <flags> <base>.cmd` capturing **stdout+stderr combined**, diffs vs `tests/expected/<base>.out`, and — when `tests/expected/<base>.csv` exists — diffs the produced `tests/work/<base>.csv` against it. Markers: `tests/<base>.exitcode`, `.sortdiff`, `.flags`. `data-vandal` `USE` accepts CSV/ODF/OOXML; `SAVE`/`RUN` writes the table (CSV by default).
- **sdata harness** (regression only): diffs stdout against `tests/expected/<base>.out`; it does **not** diff produced CSVs. We add no sdata tests; we only keep it green.
- **Current behavior:** `Infer_Column_Types` (CSV) and `Apply_Dollar_Override` (ODF/OOXML) honor only `$`→`Col_String`; default `Col_Numeric`; data inference flips numeric→string on a non-numeric value. A `%` header is ignored today (loads numeric/float — confirmed earlier: `N%` rendered `9.90000E+01`).
- **`Coerce_Value`** (`sdata_core-table.adb:260`) already truncates `Val_Numeric`→`Val_Integer` toward zero, and **raises `Type_Mismatch_Error` for `Val_String`→`Col_Integer`**. The CSV loader has **no** try/catch around `Set_Value_Upper` (so that exception would abort the load — Task 1 prevents it). The ODF and OOXML data-row loaders **already** wrap `Set_Value` in `when E : others` handlers that warn + skip, so a string-into-integer cell is already handled there (warn + missing); Task 2 only adds the non-integer-numeric truncation warning.
- **Output unchanged:** `Val_Integer` renders plain via `To_String_Formatted`; an integer column's name always ends in `%`, so it round-trips.

### Repo / PR structure (two PRs)

- **sdata-core** branch `feature/percent-header-integer-columns` (exists; spec + this plan committed): loader/helper code (Tasks 1–2) → its own PR.
- **data-vandal** new branch `feature/percent-header-integer-columns`: all new tests + fixtures (Tasks 1–2) → its own PR, noting it exercises the sdata-core change (path-pinned, so it works locally before either merges).
- **sdata**: no commits expected; just `make check` for regression (Task 3). Only commit there if a pre-existing sdata test legitimately needs a golden update.

Develop and test everything locally (path pins make this seamless); split into PRs in Task 3.

---

## File Structure

| File | Change |
|---|---|
| `sdata-core/src/sdata_core-file_io-csv.adb` | `%`→`Col_Integer` in `Infer_Column_Types`; integer-cell handling (truncation warning; non-numeric→missing+warn) |
| `sdata-core/src/sdata_core-file_io-helpers.ads` / `.adb` | Rename+generalize `Apply_Dollar_Override` → `Apply_Name_Suffix_Types` (`$`→string, `%`→integer) |
| `sdata-core/src/sdata_core-file_io-odf.adb` / `…-ooxml.adb` | Call renamed helper; authoritative-suffix guard in the data scan; truncation warning in the data-row loader |
| `data-vandal/tests/data/*.csv`, `*.ods`, `*.xlsx` | New fixtures |
| `data-vandal/tests/percent_*.{cmd,out,csv}` | New integration tests |

---

## Task 1: CSV `%`→integer (code) + CSV tests in data-vandal

**Files:**
- Modify: `~/Develop/sdata-core/src/sdata_core-file_io-csv.adb`
- Tests (data-vandal): `tests/data/percent_int.csv`, `tests/data/percent_mixed.csv`; `tests/percent_int.cmd`(+`.out`,`.csv`), `tests/percent_mixed.cmd`(+`.out`,`.csv`)

- [ ] **Step 1: Write the failing CSV integer test (data-vandal)**

Fixture `~/Develop/data-vandal/tests/data/percent_int.csv`:
```
N%,V
1,10
2,20
3,30
```
`~/Develop/data-vandal/tests/percent_int.cmd`:
```
-- percent_int: a %-suffixed CSV header types the column as integer, so N%
-- renders as plain integers (V, no suffix, stays numeric/float).
USE "tests/data/percent_int.csv"
SAVE "tests/work/percent_int.csv"
RUN
QUIT
```
`~/Develop/data-vandal/tests/expected/percent_int.out`:
```
Dataset opened: tests/data/percent_int.csv
Dataset saved: tests/work/percent_int.csv
```
`~/Develop/data-vandal/tests/expected/percent_int.csv`:
```
N%,V
1,1.00000E+01
2,2.00000E+01
3,3.00000E+01
```

- [ ] **Step 2: Confirm it fails**

`cd ~/Develop/data-vandal && make check 2>&1 | grep -A3 "percent_int\.\|percent_int "`
Expected: FAIL — today `N%` loads numeric, so the CSV shows `1.00000E+00` not `1` (csv mismatch).

- [ ] **Step 3: Add `%`→`Col_Integer` to `Infer_Column_Types`**

In `sdata-core/src/sdata_core-file_io-csv.adb`, in the header-suffix loop, extend the `$` check:
```ada
                     if Raw'Length > 0 and then Raw (Raw'Last) = '$' then
                        Col_Types.Replace_Element (I, Col_String);
                        Col_Determined (I) := True;
                     elsif Raw'Length > 0 and then Raw (Raw'Last) = '%' then
                        Col_Types.Replace_Element (I, Col_Integer);
                        Col_Determined (I) := True;
                     end if;
```

- [ ] **Step 4: Handle integer-column cells in the cell builder**

In the same file's field-to-`Val` block:

(a) In the `elsif Try_Fast_Float (F, Num) then` branch, warn (then let `Coerce_Value` truncate) for a non-integer numeric in an integer column:
```ada
                     elsif Try_Fast_Float (F, Num) then
                        if Col_Types (Field_Count) = Col_Integer
                           and then Num /= Float'Truncation (Num)
                        then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-integer value """ & F &
                               """ in integer column -- truncated");
                        end if;
                        Val := (Kind => Val_Numeric, Num_Val => Num);
```

(b) In the non-numeric `else` branch, add an `elsif` for `Col_Integer` (store missing + warn — otherwise `Val_String` → `Coerce_Value` raises and aborts the load). Keep the existing `Col_Numeric` message byte-for-byte:
```ada
                     else
                        if Col_Types (Field_Count) = Col_Numeric then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-numeric value """ & F &
                               """ in numeric column -- stored as missing");
                           Val := (Kind => Val_Missing);
                        elsif Col_Types (Field_Count) = Col_Integer then
                           SData_Core.IO.Put_Line_Error
                              ("Warning: """ & File_Name & """, data row" &
                               Natural'Image (Rows_Written) & ", column """ &
                               Col_Names (Field_Count).all &
                               """: non-numeric value """ & F &
                               """ in integer column -- stored as missing");
                           Val := (Kind => Val_Missing);
                        else
                           Val := (Kind    => Val_String,
                                   Str_Val => To_Unbounded_String (F));
                        end if;
                     end if;
```

- [ ] **Step 5: Build + confirm the integer test passes**

`cd ~/Develop/data-vandal && make check 2>&1 | grep -E "percent_int|tests passed|FAILED"`
Expected: `percent_int` PASSED, all pass.

- [ ] **Step 6: Add the truncation + non-numeric CSV test**

Fixture `~/Develop/data-vandal/tests/data/percent_mixed.csv`:
```
N%,V
1,10
1.5,20
abc,30
```
`~/Develop/data-vandal/tests/percent_mixed.cmd`:
```
-- percent_mixed: in a % column, a non-integer numeric truncates (with a
-- warning) and a non-numeric is stored missing (with a warning); the load
-- does not abort.
USE "tests/data/percent_mixed.csv"
SAVE "tests/work/percent_mixed.csv"
RUN
QUIT
```
Generate the goldens by running the built binary, then inspect:
```bash
cd ~/Develop/data-vandal
./bin/data-vandal tests/percent_mixed.cmd > tests/expected/percent_mixed.out 2>&1
cp tests/work/percent_mixed.csv tests/expected/percent_mixed.csv
cat tests/expected/percent_mixed.out tests/expected/percent_mixed.csv
```
Verify: the CSV `N%` column reads `1`, `1` (truncated from `1.5`), blank (from `abc`); the `.out` contains both the "in integer column -- truncated" warning (row 2) and the "in integer column -- stored as missing" warning (row 3). If warnings appear in a different absolute order than the CSV write messages, just commit the generated `.out` as-is (it is the true output).

- [ ] **Step 7: Run the suite**

`cd ~/Develop/data-vandal && make check 2>&1 | grep -E "percent_|tests passed|FAILED"`

- [ ] **Step 8: Commit (both repos)**

```bash
cd ~/Develop/sdata-core
git add src/sdata_core-file_io-csv.adb
git commit -m "feat(csv): type %-suffixed header columns as integer on load

A CSV column whose header ends in % is now Col_Integer (mirroring the
\$ -> Col_String rule). Integer cells store as Val_Integer; non-integer
numerics truncate toward zero with a warning; non-numerics warn and
store missing (so Coerce_Value never raises and aborts the load).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"

cd ~/Develop/data-vandal
git checkout -b feature/percent-header-integer-columns
git add tests/data/percent_int.csv tests/percent_int.cmd tests/expected/percent_int.out tests/expected/percent_int.csv \
        tests/data/percent_mixed.csv tests/percent_mixed.cmd tests/expected/percent_mixed.out tests/expected/percent_mixed.csv
git commit -m "test(csv): %-header integer columns (load, truncate, non-numeric)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ODF/OOXML `%`→integer (code) + spreadsheet tests in data-vandal

**Files:**
- Modify: `~/Develop/sdata-core/src/sdata_core-file_io-helpers.ads`, `…-helpers.adb`, `…-odf.adb`, `…-ooxml.adb`
- Tests (data-vandal): fixtures `tests/data/percent_int.ods`, `tests/data/percent_int.xlsx` (generated, see Step 5); `tests/percent_ods.cmd`(+`.out`,`.csv`), `tests/percent_xlsx.cmd`(+`.out`,`.csv`)

- [ ] **Step 1: Generalize the shared helper**

`sdata-core/src/sdata_core-file_io-helpers.ads` — rename the declaration to `Apply_Name_Suffix_Types` (same parameters). `…-helpers.adb` — replace the body:
```ada
   procedure Apply_Name_Suffix_Types
      (Col_Name_Vec : Name_Vecs.Vector;
       Col_Types    : in out Column_Type_Array) is
   begin
      for I in 1 .. Natural (Col_Name_Vec.Length) loop
         declare
            Raw : constant String := To_String (Col_Name_Vec (I));
         begin
            if Raw'Length > 0 and then Raw (Raw'Last) = '$' then
               Col_Types (I) := Col_String;
            elsif Raw'Length > 0 and then Raw (Raw'Last) = '%' then
               Col_Types (I) := Col_Integer;
            end if;
         end;
      end loop;
   end Apply_Name_Suffix_Types;
```

- [ ] **Step 2: Update both call sites + authoritative-suffix guard**

In `sdata-core/src/sdata_core-file_io-odf.adb` (`Infer_And_Create_ODF_Schema`): change the call to `Apply_Name_Suffix_Types`, and guard the data scan so a `%`-forced integer column is not flipped to string:
```ada
            Apply_Name_Suffix_Types (Col_Name_Vec, Col_Types);
            ...
                     if Col_Types (Col_Idx) /= Col_Integer
                        and then Get_Cell_Value (Item (Data_Cells, J)).Kind
                                 = Val_String
                     then
                        Col_Types (Col_Idx) := Col_String;
                     end if;
```
Make the identical two changes in `sdata-core/src/sdata_core-file_io-ooxml.adb` (its `Apply_Dollar_Override` call and its `if Get_Cell_Value (...).Kind = Val_String` scan). The `Final_Name` `$`-append logic touches only `Col_String`, so integer columns pass through with their existing `%` name unchanged — leave it.

- [ ] **Step 3: Add the truncation warning to the ODF/OOXML data-row loaders**

A `Val_String` into a `Col_Integer` column already raises → caught by the existing `when E : others` handler → warn + skip (missing), satisfying "non-numeric → warn + missing". Add only the non-integer-numeric truncation warning before `Set_Value`. In `Load_ODF_Data_Rows`, where `Val` and `Col_Idx` are in scope, just before `if Val.Kind /= Val_Missing then Set_Value (...)`:
```ada
                                    if Val.Kind = Val_Numeric
                                       and then SData_Core.Table.Get_Column_Type
                                          (Column_Name (Col_Idx)) = Col_Integer
                                       and then Val.Num_Val
                                          /= Float'Truncation (Val.Num_Val)
                                       and then not SData_Core.Config.Quiet_Mode
                                    then
                                       Put_Line_Error
                                          ("Warning: ODF import, row" &
                                           Row_Count'Image & ", column """ &
                                           Column_Name (Col_Idx) &
                                           """: non-integer value truncated");
                                    end if;
```
Make the analogous insertion in the OOXML data-row loader using `V`, `Column_Name (J + 1)`, and `"OOXML import"`. Confirm `SData_Core.Table.Get_Column_Type` and `SData_Core.Config` are visible in each unit; add the `with`/`use` if the build complains.

- [ ] **Step 4: Build**

`cd ~/Develop/data-vandal && make check 2>&1 | tail -3`. Fix any compile error (a missed `Apply_Dollar_Override` reference, or `Get_Column_Type`/`Config` visibility). Existing tests should still pass at this point (no spreadsheet `%` fixtures yet).

- [ ] **Step 5: Generate the `.ods` / `.xlsx` fixtures**

The spreadsheet readers are tested by loading a fixture whose header is `N%` and writing it back to CSV. Generate the binary fixtures from the CSV by round-tripping through the built tool (native `sdata-core` writers; no LibreOffice needed for writing). Use whichever built binary supports `SAVE` to `.ods`/`.xlsx` — `bin/data-vandal` with `/FMT`:
```bash
cd ~/Develop/data-vandal
printf 'USE "tests/data/percent_int.csv"\nSAVE "tests/data/percent_int.ods" /FMT=ods\nRUN\nQUIT\n'  > /tmp/mk_ods.cmd
printf 'USE "tests/data/percent_int.csv"\nSAVE "tests/data/percent_int.xlsx" /FMT=xlsx\nRUN\nQUIT\n' > /tmp/mk_xlsx.cmd
./bin/data-vandal /tmp/mk_ods.cmd && ./bin/data-vandal /tmp/mk_xlsx.cmd
ls -l tests/data/percent_int.ods tests/data/percent_int.xlsx
```
(If `data-vandal`'s `SAVE` cannot emit `.ods`/`.xlsx`, generate the fixtures with the built `~/Develop/sdata/bin/sdata` instead — `sdata` definitely writes spreadsheets, e.g. `save_bracket_sheet.cmd` — then copy them into `data-vandal/tests/data/`.) The fixture only needs the header `N%`; the reader keys on the header, not the stored cell type, so this is a valid test of the reader's `%` handling.

- [ ] **Step 6: Write the spreadsheet tests + generate goldens**

`~/Develop/data-vandal/tests/percent_ods.cmd`:
```
-- percent_ods: the ODF reader honors a %-suffixed header (N% loads as
-- integer). Reads the .ods fixture and writes CSV; N% must render as
-- plain integers, proving the reader typed it integer (not float).
USE "tests/data/percent_int.ods"
SAVE "tests/work/percent_ods.csv"
RUN
QUIT
```
`~/Develop/data-vandal/tests/percent_xlsx.cmd` — same with `percent_int.xlsx` / `percent_xlsx.csv`.
Generate goldens by running the built binary, then inspect that `N%` is `1`,`2`,`3` (plain integers) in each produced CSV:
```bash
cd ~/Develop/data-vandal
for t in percent_ods percent_xlsx; do
  ./bin/data-vandal "tests/$t.cmd" > "tests/expected/$t.out" 2>&1
  cp "tests/work/$t.csv" "tests/expected/$t.csv"
done
cat tests/expected/percent_ods.csv tests/expected/percent_xlsx.csv
```
If `N%` comes back as `1.00000E+00` rather than `1`, the spreadsheet reader change (Steps 1–2) is not taking effect — STOP and fix before committing the goldens.

- [ ] **Step 7: Run the suite**

`cd ~/Develop/data-vandal && make check 2>&1 | grep -E "percent_ods|percent_xlsx|tests passed|FAILED"`

- [ ] **Step 8: Commit (both repos)**

```bash
cd ~/Develop/sdata-core
git add src/sdata_core-file_io-helpers.ads src/sdata_core-file_io-helpers.adb \
        src/sdata_core-file_io-odf.adb src/sdata_core-file_io-ooxml.adb
git commit -m "feat(odf,ooxml): type %-suffixed header columns as integer on load

Generalize the shared \$-override helper to also map % -> Col_Integer,
guard the data scan so the suffix typing is authoritative (a string cell
no longer flips a % column to string), and warn when a non-integer
numeric is truncated into an integer column. (A string cell in an
integer column is already warned + skipped by the existing Set_Value
try/catch.)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"

cd ~/Develop/data-vandal
git add tests/data/percent_int.ods tests/data/percent_int.xlsx \
        tests/percent_ods.cmd tests/expected/percent_ods.out tests/expected/percent_ods.csv \
        tests/percent_xlsx.cmd tests/expected/percent_xlsx.out tests/expected/percent_xlsx.csv
git commit -m "test(odf,ooxml): %-header columns load as integer from spreadsheets

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Cross-suite regression, goldens, version, finishing

- [ ] **Step 1: Full regression in both consumer suites**
```bash
cd ~/Develop/data-vandal && make check
cd ~/Develop/sdata        && make check
```
Both must end green. `sdata` has spreadsheet/CSV fixtures; if any FAILS specifically because it loads a `%`-headed column that now (correctly) types integer, that is an expected golden change — handle in Step 2. If a failure is anything else, investigate (it is a real regression).

- [ ] **Step 2: Update goldens for any pre-existing `%`-column tests**
For each sdata (or data-vandal) test that failed in Step 1 *because* of the new `%` typing, regenerate and review its expected output, confirming the new integer rendering is intended; commit on a branch in that repo and list each changed test in the message. If none failed for this reason, state that explicitly and skip.

- [ ] **Step 3: Version bump (sdata-core)**
Check `~/Develop/sdata-core` for a `scripts/bump-version.sh`; if present, bump the **minor** version (feature addition) and answer its prompts to commit but **not** tag (the tag lands on the default branch after merge). If consumers pin a minimum `sdata_core` version in `alire.toml`, raise it in both `data-vandal` and `sdata`. If there is no bump script / versioning differs, note it and skip.

- [ ] **Step 4: Final green check**
Commit any version/pin edits, then re-run `make check` in both `data-vandal` and `sdata`; confirm green.

- [ ] **Step 5: Finishing — open PRs**
Use **superpowers:finishing-a-development-branch**. Confirm with the user before pushing (pushing is outward-facing), then push and open:
1. **sdata-core** PR (`feature/percent-header-integer-columns` → default): loader/helper code + spec + plan.
2. **data-vandal** PR (`feature/percent-header-integer-columns` → default): new tests + fixtures (+ any pin bump), noting it relies on the sdata-core PR.
PR descriptions: state the `%`→integer behavior, the suffix-authoritative rule, the truncate+warn / non-numeric→missing semantics, and the cross-consumer nature.

---

## Notes on conventions

- **POSIX shell** in any scripts/recipes.
- **Separate commits per repo** (sdata-core code vs data-vandal tests) since they become separate PRs.
- **Match the existing CSV `Col_Numeric` warning wording byte-for-byte**; integer columns get their own parallel messages.
- **Suffix typing is authoritative** — the ODF/OOXML data scan must not flip a `Col_Integer` column to `Col_String` (the `/= Col_Integer` guard).
- **No edits to `Coerce_Value`, the value model, or the writers** (spec §3.3 / §6).
- **Ada line length** — follow sdata-core's `-gnaty` settings (check its `.gpr`/build flags); keep new lines within the enforced limit.
- A `Col_Integer` value renders plain via `To_String_Formatted`; do not add any output-side formatting.
