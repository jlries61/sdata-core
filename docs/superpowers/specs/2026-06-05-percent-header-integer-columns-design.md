# `%`-header → integer columns on load — Design Specification

**Date:** 2026-06-05
**Status:** Approved
**Scope:** `sdata-core` file loaders (CSV / ODF / OOXML); consumed by both
`sdata` and `data-vandal`.

---

## 1. Overview

A column whose **header name ends in `%`** is typed `Col_Integer` when a
dataset is loaded — the exact mirror of the existing rule that a header ending
in `$` is typed `Col_String`. Today no loader honors `%`: a `N%` header loads
as `Col_Numeric` (float), even though `%` already denotes an integer column
everywhere else in the system (DIM/subscripted array columns in
`sdata_core-variables.adb`, the `Col_Integer`→`INTEGER` SQLite mapping, and
`VANDALIZE … INTO dest%` in data-vandal). This change completes that
convention at the file-loading boundary.

### 1.1 Motivation

- **Symmetry.** `$`→string is honored on load; `%`→integer is not. The
  asymmetry is surprising and was surfaced concretely while testing
  data-vandal's `/SENTINEL` flag (an integer column could only be obtained via
  `VANDALIZE INTO K%`, never by loading a `%`-headed file).
- **Round-trip stability (bonus).** A `Col_Integer` column produced by other
  means (DIM arrays, `VANDALIZE INTO K%`) is written back with a `%`-suffixed
  header and plain-integer cells, but **reloads as `Col_Numeric`** today —
  a save→reload type change. Honoring `%` on load makes the round-trip
  type-stable.

---

## 2. Semantics

### 2.1 Type inference (suffix-only, authoritative)

A column is `Col_Integer` **iff its header name ends in `%`**. This is
suffix-only: data inference continues to distinguish only numeric vs string
(it never auto-types a column integer). Consequently **no existing dataset
changes behavior unless its header already carries `%`** — an all-integer
column with no suffix still loads as `Col_Numeric` (float), exactly as today.

The suffix typing is **authoritative**: a `%`-forced `Col_Integer` (like a
`$`-forced `Col_String`) must **not** be overridden by the per-cell data scan.

### 2.2 Per-cell behavior in a `%` column

| Cell text | Stored value |
|---|---|
| integer, e.g. `5` | `Val_Integer (5)` (renders as a plain integer) |
| non-integer numeric, e.g. `1.5` | **truncate toward zero → `Val_Integer (1)`, and emit a per-cell warning** |
| non-numeric, e.g. `abc` | **warn and store `Val_Missing`** (mirrors a non-numeric value in a numeric column) |
| empty or `.` | `Val_Missing` |

Truncation is toward zero (`Integer (Float'Truncation (x))`), consistent with
the existing `Coerce_Value` (`sdata_core-table.adb:272`). The non-numeric→missing
behavior is required: without it, a string value flowing into a `Col_Integer`
column reaches `Coerce_Value`, which raises `Type_Mismatch_Error` and aborts the
whole load.

### 2.3 Output / round-trip

**No writer change.** A `Col_Integer` value already renders as a plain integer
via `To_String_Formatted`. A `Col_Integer` column's name always ends in `%`
(integer typing only ever comes from the suffix), so it is written back with
its `%` header and reloads as `Col_Integer` — a stable round-trip. Unlike the
`$` case, no header-suffix *appending* is needed on write, because integer
columns are never produced by data inference (only by the explicit suffix).

---

## 3. Implementation (all in `sdata-core`)

### 3.1 CSV — `sdata_core-file_io-csv.adb`

- **`Infer_Column_Types`:** in the header-suffix pass, add a `%`→`Col_Integer`
  branch alongside the existing `$`→`Col_String` branch, and set the existing
  `Col_Determined` flag so the data scan does not re-type it.
- **Cell builder (~lines 220-241):**
  - When a field parses as a float (`Try_Fast_Float`) **and** the column is
    `Col_Integer` **and** the value is non-integral, emit a truncation warning.
    The value remains `Val_Numeric`; `Coerce_Value` truncates it to
    `Val_Integer` at `Set_Value_Upper`. (Integer-valued fields need no special
    handling — `Coerce_Value` converts them losslessly and silently.)
  - Extend the "non-numeric value → warn + store missing" branch (currently
    gated on `Col_Types (…) = Col_Numeric`) to also cover `Col_Integer`, so a
    non-numeric field in an integer column is stored missing rather than
    raising `Type_Mismatch_Error`.

### 3.2 ODF / OOXML — `sdata_core-file_io-odf.adb`, `…-ooxml.adb`, `…-helpers.adb`

- **Shared helper:** generalize `Apply_Dollar_Override`
  (`sdata_core-file_io-helpers.adb`) to also apply `%`→`Col_Integer`. Rename it
  to reflect both suffixes (e.g. `Apply_Name_Suffix_Types`) and update both call
  sites.
- **Authoritative override:** both loaders currently run the suffix helper and
  then let the per-cell data scan set `Col_String` for any column containing a
  string cell. That scan must **not** flip a `%`-forced `Col_Integer` to
  `Col_String`. Add a "suffix-determined" guard (mirroring CSV's
  `Col_Determined`) so suffix typing wins. (For `$` this was a harmless no-op;
  for `%` it is required.)
- **Per-cell handling:** the ODF/OOXML data-row builders construct values via
  `Get_Cell_Value` (`Val_Numeric`/`Val_String`/`Val_Missing`) and call
  `Set_Value`. Apply the same policy as CSV for `Col_Integer` columns: warn on
  non-integral numeric (then rely on `Coerce_Value` truncation), and warn +
  store missing on a string cell (rather than letting `Coerce_Value` raise).

### 3.3 No change to `sdata-core-table.adb` or any writer

`Coerce_Value` already truncates `Val_Numeric`→`Val_Integer`; the writers
already render `Val_Integer` plainly and preserve the `%` header.

---

## 4. Testing

New tests (in `sdata-core`'s own suite where it has one, and/or via the
consumer suites) covering, for each affected loader:

1. **Integer load + render** — a `%`-headed column of integers loads as
   `Col_Integer` and round-trips as plain integers (no decimal / E-notation).
2. **Float truncation + warning** — `1.5` in a `%` column becomes `1` and emits
   the truncation warning.
3. **Non-numeric → missing + warning** — `abc` in a `%` column is stored missing
   with a warning and does **not** abort the load.
4. **Authoritative suffix (ODF/OOXML)** — a `%` column containing a string cell
   stays `Col_Integer` (string cell → missing), not reclassified to `Col_String`.
5. **Save→reload round-trip** — a `Col_Integer` column (e.g. created by
   `VANDALIZE INTO K%` or a DIM array) saves and reloads as `Col_Integer`.

### 4.1 Cross-consumer obligation

This is shared-library code. After the change, **re-run both consumer suites**
and update any goldens for existing tests that happen to use `%`-headed
columns:

```sh
cd ~/Develop/sdata-core   # (build/unit tests, if any)
cd ~/Develop/data-vandal  && make check
cd ~/Develop/sdata        && make check
```

Existing `%`-headed columns in either suite will now load as integer (plain
rendering, possible truncation warnings); their expected outputs must be
regenerated and reviewed.

---

## 5. Versioning

`sdata-core` carries its own version. Bump per its release process once the
change lands; raise the `sdata_core` constraint in `data-vandal/alire.toml`
(and `sdata`'s) if/when a published release is cut. During path-pinned
development the consumers pick up the change directly.

---

## 6. Out of scope

- **Data-inferred integer typing** (auto-typing an all-integer numeric column
  as integer without a `%` suffix) — explicitly rejected (§2.1); it would
  change existing datasets' behavior and risk wide golden churn.
- **A `%`-append on write** for integer columns — unnecessary, since integer
  columns always already carry the `%` suffix in their name.
- **Rounding modes** other than truncate-toward-zero — out of scope; matches the
  existing `Coerce_Value` semantics.
- Any change to `Coerce_Value`, the value model, or the output writers.
