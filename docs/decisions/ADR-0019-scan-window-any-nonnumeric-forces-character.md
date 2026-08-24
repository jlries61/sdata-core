---
id: ADR-0019
title: "CSV scan-window type inference: any non-numeric value in the window forces character (not first-value-wins)"
status: Accepted
date: 2026-08-24
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd6-scan-window-type-inference/00-brief.md
  - ../../../sdata/.ssd/features/pd6-scan-window-type-inference/01-architect.md
---

# ADR-0019: CSV scan-window type inference implements "any non-numeric forces character"

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-6**, `part-d-file-io-execution-model.md`) found that
design.md's `USE` command reference (§7.1) documents: "any column with non-numeric values in any of
the first *n* rows (if there are that many) will be taken as character." `Infer_Column_Types`
(`sdata_core-file_io-csv.adb`) instead took the type of the **first** non-empty, non-`.` value in the
scan window and locked it in immediately (`Col_Determined (I) := True`) — a column whose first value
was numeric stayed numeric for the rest of the scan window even if later values in that same window
were non-numeric, contradicting the documented rule.

The audit itself declined to pick a resolution, framing this as a genuine design-vs-code question:
the old behavior is defensible (cheaper, produces per-value diagnostics instead of silently
reclassifying a mostly-numeric column over one early stray bad value), but is materially different
from what's documented. Presented both of the audit's recommended resolutions to the user directly:
implement the documented rule (real behavior change) vs. rewrite design.md to match the code (no
behavior change). **The user chose to implement the documented rule.**

## Decision

`Infer_Column_Types`'s scan-window loop now locks in a column's type (`Col_Determined (I) := True`)
only when a **non-numeric** substantive value is found. A numeric value leaves the column at its
existing `Col_Numeric` default (set once, before the loop, for all columns) and does not lock in —
the loop keeps scanning that column's remaining rows in the window. The header-driven `$`/`%`-suffix
branch, which already sets `Col_Determined (I) := True` before the scan-window loop runs at all, is
untouched.

Result: a column's final type after the scan window is `Col_String` if *any* value in the window was
non-numeric, `Col_Numeric` otherwise — matching design.md §7.1 exactly.

## Rationale

The fix is a minimal, precisely-targeted change to the one condition the audit already isolated as the
divergence point — no new state, no new types, no signature changes. It directly implements the rule
as literally documented, resolving the ambiguity the audit raised in the direction the user explicitly
chose (over the audit's own initial framing that the *code's* behavior might be the more defensible
one — a judgment call correctly left to the user, not decided unilaterally by either the audit or this
implementation).

## Consequences

**Easier**: column typing now matches its own documentation precisely; a user reading design.md's rule
gets the behavior it describes.

**Harder / disclosed breaking change**: any script — this project's own tests or a real user's — that
relied on the old first-value-wins behavior for a column with a numeric first value and later
non-numeric values will see that column retyped character (name gains `$`, all values become string
rather than numeric-with-per-value-missing-for-bad-rows) after upgrading. A static pre-scan of every
`tests/data/*.csv` fixture in the sdata repo found exactly one column (`tests/data/type_mismatch.csv`,
column `VALUE`) that would flip, and confirmed it is not exercised by any current test — the practical
blast radius on this project's own fixtures is small, though the full empirical suite run (not the
static pre-scan) is the authoritative check performed before shipping.

**Version bump**: minor (0.11.2 → 0.12.0), not patch, per this project's established convention that
changes to a default's *behavior* for previously-valid input are minor even without a signature
change (matching ADR-0016's `--clen` default precedent).

## Alternatives Rejected

**Rewriting design.md to describe the actual first-value-wins behavior instead** — the audit's other
recommended resolution, explicitly offered to the user via `AskUserQuestion` and declined in favor of
implementing the documented rule.

**Folding in ODF/OOXML's own, narrower type-inference gap** (they inspect only the single first data
row, not an NSCAN-row window, to possibly upgrade a column to character) — rejected as a *different*
bug shape (window size, not within-window algorithm) than what PD-6 reports or what the user was asked
to decide on. Flagged as a candidate future finding, not resolved here.
