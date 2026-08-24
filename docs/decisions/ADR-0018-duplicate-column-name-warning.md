---
id: ADR-0018
title: "Duplicate column name warning: shared Warn_If_Duplicate_Name helper in File_IO.Helpers, checked on the decorated name (amended: ODF/OOXML row-loading fix)"
status: Accepted (amended — see Amendment below)
date: 2026-08-24
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd5-duplicate-column-warning/00-brief.md
  - ../../../sdata/.ssd/features/pd5-duplicate-column-warning/01-architect.md
---

# ADR-0018: Duplicate column name warning: shared `Warn_If_Duplicate_Name` helper

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-5**, `part-d-file-io-execution-model.md`) found that
design.md §4.2 and the `USE` command's §7.1 row both document "duplicate column names: last
occurrence wins, warning issued." The audit verified the "last occurrence wins" half against CSV only
and found it correct there — a side effect of `SData_Core.Table.Add_Column`'s idempotent-by-name
behavior (a duplicate name's second `Add_Column` call silently no-ops, so both same-named header
positions write to the one physical column created by the first occurrence, and CSV's row processing
writes fields by name in order, so the *last* field with that name is naturally the one whose value
survives). The warning half was never implemented — `grep -rn "uplicate" sdata-core/src/*.adb` finds
zero matches near header/column-name construction. (**Correction, see Amendment below**: "last
occurrence wins" turned out NOT to be correct for ODF/OOXML — only for CSV.)

Investigation this session (not named by the audit, which cited only CSV) found the identical gap
independently present in **all three file readers**: `sdata_core-file_io-csv.adb`'s
`Infer_Column_Types`, and the near-identical naming loops in `sdata_core-file_io-odf.adb`'s
`Infer_And_Create_ODF_Schema` and `sdata_core-file_io-ooxml.adb`'s `Infer_And_Create_OOXML_Schema` —
none of the three ever checks a newly-computed column name against names already processed before
calling `Add_Column`. design.md §4.2's promise is not CSV-scoped wording, so all three are in scope
for one workstream rather than three separately-filed findings.

## Decision

A new private helper, `SData_Core.File_IO.Helpers.Warn_If_Duplicate_Name (File_Name, Final_Name :
String; Seen : in out Name_Vecs.Vector)`, called from all three readers' naming loops immediately
before each format's own `Add_Column` (or, for CSV, `Col_Names.Append`) call. It scans `Seen`
case-insensitively for `Final_Name`; if found, emits a warning naming both the file and the column;
unconditionally appends `Final_Name` to `Seen` regardless, so a third or later occurrence of the same
name also warns (comparing against every prior occurrence, not just the immediately preceding one).

The check operates on `Final_Name` — the fully `$`-suffix-decorated name actually passed to
`Add_Column` — not the raw header text, and normalizes case via `Ada.Characters.Handling.To_Upper`,
the identical function `SData_Core.Column_Names.To_Column_Name` itself uses for its own collision key.

## Rationale

**Shared helper, not three inline checks.** `SData_Core.File_IO.Helpers` (a `private package`, not
part of sdata-core's public API) already exists as the home for logic shared across ≥2 of the three
readers — `Apply_Name_Suffix_Types` is the direct precedent, already shared between ODF and OOXML.
The three naming loops this fix touches are already near-identical in shape; triplicating the same
case-insensitive scan-and-warn logic would be exactly the kind of copy-paste `File_IO.Helpers` exists
to avoid, and would leave three independent places to keep in sync if the warning's wording or
normalization ever needs to change.

**Decorated name, not raw header text.** `Table.Add_Column`'s own collision key operates on whatever
string is actually passed to it (the decorated name), not the raw header. A check against the raw
name could disagree with what the table itself will actually treat as a collision — either warning
when no real collision will occur, or staying silent when one will. Checking the identical string
`Add_Column` receives is the only choice that can't diverge from the table's actual behavior.

## Consequences

**Easier**: all three file readers now emit the documented warning, closing the gap between
design.md's promise and the implementation for the class of bug PD-5 reports — a duplicate column
name that silently drops data (the earlier occurrence's values) with no diagnostic.

**Unchanged**: `Add_Column`'s own call and arguments, at all three call sites, are untouched — the new
code is purely additive (a helper call inserted immediately before the pre-existing
`Add_Column`/`Col_Names.Append` line). "Last occurrence wins" behavior is not altered in any way; only
the missing diagnostic is added.

**Neutral**: three symmetric call-site edits (one new local `Seen` declaration + one procedure call
each) rather than a single larger change threading shared state across formats — matches the
independent, format-siloed structure the three readers already have.

## Alternatives Rejected

**Checking inside `Table.Add_Column` itself** — rejected. `Add_Column` is the general-purpose
column-creation primitive also used by MERGE, AGGREGATE/TRANSPOSE output, and other non-file-loading
paths that don't have a `File_Name` in scope and where "duplicate column name" isn't the right framing
(some of those paths deliberately reuse an existing output column name). Keeping the check at the
three file-loading call sites, where "this name came from a file the user is loading" context
genuinely exists, matches the audit's own recommended fix location and avoids false-positive warnings
in unrelated column-creation paths.

## Amendment (2026-08-24, same session): ODF/OOXML did not actually implement "last occurrence wins"

While building the ODF/OOXML regression fixtures for the warning fix above, empirical testing (a
3-column header with a duplicate, e.g. `NAME,SCORE,name`) found the "last occurrence wins" half of
design.md §4.2's promise — which the audit verified for CSV and which this ADR's original Context
assumed held universally — is **false for ODF and OOXML**. Both readers' row-loading loops
(`Load_ODF_Data_Rows`, `Load_OOXML_Data_Rows`) bound the number of cells processed per row by
`Table.Column_Count` (the *physical*, deduplicated column count) while indexing cells by their *raw*
position in the file. Whenever an earlier duplicate shrinks the physical column count below the raw
header count, every cell at or beyond the new, smaller bound — the duplicate's own later occurrence,
and any genuinely distinct column after it — is silently dropped, never written anywhere. The value
that survives is whichever occurrence happened to fall within the truncated bound (in practice, the
*first* occurrence for the simple two-duplicate case), not the last. This is worse than PD-5's
originally reported gap: not a missing diagnostic, but silent, positionally-dependent data loss.

**Decision (amendment):** thread the *raw*, per-column decorated name list (one entry per original
header position, duplicates included — exactly what `Infer_And_Create_{ODF,OOXML}_Schema` already
computes internally as `Final_Name` on each loop iteration) out of the schema-inference procedures
(new `out Final_Names : Name_Vecs.Vector` parameter) and into the row-loading procedures, replacing
each format's `Col_Count : Natural` (physical) parameter with a `Col_Names : Name_Vecs.Vector` (raw)
parameter. Row-loading now looks up each cell's target column **by the raw name at that cell's
position**, and writes via `Set_Value` — which resolves duplicates to the one physical column by name,
exactly like CSV's existing `Set_Value_Upper` mechanism. This makes the *last* cell with a given name
the one whose value survives (matching CSV, matching the documented promise) and stops any later,
non-duplicate column from being truncated away just because an earlier duplicate shrank the physical
column count.

**Rationale:** this is the mechanism CSV already uses correctly (`Process_Line_Direct` writes
`Set_Value_Upper (Row_Count, Col_Names (Field_Count).all, Val)` — by name, using the raw per-field
name list, letting the table's own by-name resolution handle duplicates). Bringing ODF/OOXML to the
same mechanism, rather than inventing a new one, is the minimal change that makes all three readers
behave identically for this case, as design.md's shared "same behavior as ODF" framing (§4.1) already
implies they should.

**Scope decision:** folded into this workstream rather than filed separately, per explicit user
choice when presented with both options — this is materially riskier than the additive warning above
(it changes row-loading logic, not just adds a diagnostic before an unchanged call), but leaving a
known, verified data-loss bug undocumented and unfixed after discovering it was judged worse than the
larger diff.

**Consequences:** `Infer_And_Create_ODF_Schema`/`Infer_And_Create_OOXML_Schema` gain a new `out`
parameter (internal, `private package`, no public API impact — same as the base decision above).
`Load_ODF_Data_Rows`/`Load_OOXML_Data_Rows`'s `Col_Count` parameter is replaced by `Col_Names`; every
`Column_Name (idx)` (physical Table lookup) reference becomes `To_String (Col_Names (idx))` (raw
per-position lookup). For any file with no duplicate column names, `Col_Names` and the physical
`Column_Name` list are element-for-element identical (both reader loops call `Add_Column` in the same
order used to build `Final_Names`), so this change is provably behavior-preserving for the common,
non-duplicate case — verified via the full pre-existing test suite showing zero diffs.
