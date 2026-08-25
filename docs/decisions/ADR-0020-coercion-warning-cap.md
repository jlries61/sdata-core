---
id: ADR-0020
title: "CSV non-numeric-value coercion warnings: cap at 10 per source file, with a suppressed-count summary"
status: Accepted
date: 2026-08-25
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd7-warning-cap/00-brief.md
  - ../../../sdata/.ssd/features/pd7-warning-cap/01-architect.md
---

# ADR-0020: Cap non-numeric-value coercion warnings at 10 per USE source file

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-7**, `part-d-file-io-execution-model.md`) found that
design.md §7.1's `USE` row documents:

> If subsequently, a non-numeric value appears in such a column, it will be taken as missing and
> a warning will be issued (maximum of 10 shall be written).

`Parse_CSV`'s `Process_Line_Direct` (`sdata_core-file_io-csv.adb`) emits this warning
unconditionally, once per occurrence, for both `Col_Numeric` and `Col_Integer` columns. There is no
counter, no cap, and no suppression. A file with 15 bad values produces 15 warnings, confirmed
empirically by the audit and unchanged since.

Sibling warnings emitted by the same procedure — non-integer-value truncation, integer out-of-range,
unclosed quote, and extra-fields-in-row (the last already has its own pre-existing single-shot
`Warned_Extra` suppression, an unrelated mechanism) — are not described by the "maximum of 10"
sentence anywhere in design.md and are explicitly out of scope for this decision.

## Decision

Add a single `Natural` counter (`Coercion_Warn_Count`), declared in `Parse_CSV`'s outer scope
alongside the existing `Rows_Written`, scoped to one `Parse_CSV` invocation (i.e. one source file —
a multi-file `USE` merge calls `Parse_CSV` once per source, so each gets its own independent cap).

- Every non-numeric-value-in-numeric/integer-column occurrence increments the counter.
- The per-occurrence warning message prints only while the counter is ≤ 10 (i.e. the first 10
  occurrences print exactly as today).
- After the file's row-processing loop completes, if the final count exceeds 10, one summary line
  prints: `Warning: "<file>": <N> additional non-numeric-value warning(s) suppressed (10 shown,
  <total> total)`, where `<N>` is the suppressed count and `<total>` is the true total.
- No summary line prints when the count is ≤ 10.

## Rationale

- **Implement the documented cap rather than delete the clause.** Matches PD-6/ADR-0019's precedent
  of favoring a real behavior fix over rewriting design.md, since the audit's own framing treats
  "maximum of 10" as intended behavior, not aspirational prose.
- **Whole-file counter, not per-column.** design.md's sentence has no per-column qualifier; a flat
  cap is the plain reading and avoids introducing new indexed state for an unrequested distinction.
- **End-of-file summary with the true count, not an immediate "at least 1 more" at occurrence #11.**
  An accurate suppressed-count is more useful, and the two-site cost (increment/gate at the warning
  site, print at the loop's end) is small.
- **Sibling warnings untouched.** They aren't described by the audited sentence; capping them would
  be uncited scope creep in the opposite direction from what the audit finding asks for.

## Consequences

**Easier:** files with pathologically many bad values (e.g. a wrong-delimiter or wrong-charset
mistake) no longer flood stderr with hundreds of near-identical lines; the summary still conveys the
true scale of the problem.

**Harder:** a test or downstream tool that greps for every individual coercion-warning line (rather
than the summary) undercounts past 10. No known consumer does this; existing tests are audited for
this pattern before shipping (see coder task list).

**Gives up:** the ability to see the exact row/column of the 11th+ occurrence without re-running with
a value below the 10-item threshold reached, or grep'ing the raw file — an accepted tradeoff, same
shape as `Warned_Extra`'s existing single-shot precedent for a different warning class.

## Alternatives Rejected

- **Per-column cap (10 per offending column, not 10 per file).** Rejected: no textual support in
  design.md, and would require indexed state keyed by column rather than a flat scalar.
- **Immediate summary at occurrence #11, replacing that warning.** Rejected: the exact suppressed
  count isn't known yet at that point without look-ahead; an end-of-file summary is strictly more
  informative for the same implementation cost.
- **Delete the "(maximum of 10 shall be written)" clause from design.md instead of implementing it.**
  Rejected per the brief's framing: the audit treats this as intended, implementable behavior in the
  same family as PD-5/PD-6, not aspirational text to be walked back.
