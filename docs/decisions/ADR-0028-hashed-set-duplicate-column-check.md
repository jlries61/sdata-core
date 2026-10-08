---
id: ADR-0028
title: "Hashed-set membership instead of linear scan for duplicate-column-name detection"
status: Accepted
date: 2026-10-08
related:
  - ADR-0018-duplicate-column-name-warning.md
  - sdata-core#156
  - ../../.ssd/features/warn-duplicate-name-perf-fix/00-brief.md
  - ../../.ssd/features/warn-duplicate-name-perf-fix/01-architect.md
---

# ADR-0028: Hashed-set membership instead of linear scan for duplicate-column-name detection

## Status

Accepted.

## Context

`Warn_If_Duplicate_Name` (`src/sdata_core-file_io-helpers.adb`, introduced by ADR-0018) is called
once per column by each of the three readers (CSV, ODF, OOXML) while building a file's final
column-name list. Its `Seen` accumulator was `Ada.Containers.Vectors (Positive, Unbounded_String)`,
and every call did a linear scan of every name seen so far, `To_Upper`-ing both sides on each
comparison. That makes the whole header pass O(columns²), with a string allocation inside the
inner loop compounding the constant factor.

A real-world 54,614-column CSV (via sdata's benchmark corpus) that loaded in ~0.66s per the
0.6.1-era `doc/performance_assessment.md` now runs 6+ minutes without completing. Synthetic timing
at 5K/10K/20K columns showed ~4x time per column doubling — textbook quadratic scaling. Filed as
sdata-core#156 and deliberately deferred until the 2026-09-26 standards-audit remediation closed;
that condition is now satisfied.

`Seen` is local to each of the three call sites and used for nothing but membership testing inside
the naming loop — confirmed by reading all three call sites in full; none reads `Seen` after the
loop. `Warn_If_Duplicate_Name` is declared in `SData_Core.File_IO.Helpers`, a `private package`,
so this is not a public-API change under the Commands/Config.Runtime stability contract.

## Decision

Replace `Name_Vecs.Vector` with a new `Name_Sets.Set`
(`Ada.Containers.Indefinite_Hashed_Sets (Element_Type => String, Hash => Ada.Strings.Hash,
Equivalent_Elements => "=")`) as `Warn_If_Duplicate_Name`'s `Seen` parameter type. Upper-case the
incoming name once; `Contains` for the membership test, `Insert` only on the non-duplicate branch.

## Rationale

`Ada.Strings.Hash` hashing the already-upper-cased string gives correct case-insensitive set
semantics without a custom case-folding hash combinator. `Indefinite_Hashed_Sets` (rather than
`Hashed_Sets`, which requires a discriminant-bounded element) is needed because no fixed maximum
column-name length is declared anywhere in this codebase. This is the smallest change that fixes
the asymptotic complexity: one helper signature, one body, three call-site declarations
(`Seen : Name_Vecs.Vector` → `Seen : Name_Sets.Set`) — nothing else in the data model, call graph,
or public surface moves.

## Consequences

- **Easier:** header-pass cost for duplicate detection goes from O(n²) to O(n) amortized; no new
  ceiling is introduced (a hashed set has no fixed-capacity limit), so the fix scales past the
  54K-column case that exposed it rather than just covering that one data point.
- **Harder:** `Seen` is no longer ordered — not a loss, since no caller ever iterated it for
  anything but membership (confirmed in the brief). The duplicate branch must *not* call `Insert`
  unconditionally: `Set.Insert` on an already-present element raises `Constraint_Error`, unlike
  `Vector.Append`, which silently duplicated harmlessly under the old scheme. This is a new
  invariant the implementation and its tests must preserve — a regression test with ≥2 duplicates
  of the *same* name in one file is required, not just one duplicate pair.
- **Gives up:** nothing user-visible. Warning text, order, and "last occurrence wins" semantics are
  unchanged for every well-formed input; the only observable difference is that wide files that
  previously hung now complete.

## Alternatives Rejected

- **Keep `Vector`, short-circuit with a separate sorted check.** Still O(n log n) per file at best,
  with a second data structure to keep in sync. No simpler than the hashed set and strictly worse
  asymptotically.
- **`Ada.Containers.Hashed_Sets` (bounded element).** Would require a fixed maximum column-name
  length, which is untrue today and would reintroduce exactly the kind of ceiling this fix exists
  to remove.
- **Cache upper-cased names in a parallel `Vector` without hashing.** Removes the repeated
  `To_Upper` allocation but the scan itself stays O(n²) — fixes the constant factor, not the
  complexity class. Rejected as a non-fix.
