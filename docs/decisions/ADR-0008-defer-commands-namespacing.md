---
id: ADR-0008
title: "Defer SData_Core.Commands sub-namespacing; record trigger conditions"
status: Accepted
date: 2026-07-24
related:
  - src/sdata_core-commands.ads
  - src/sdata_core-commands.adb
  - ADR-0007
---

# ADR-0008: Defer SData_Core.Commands sub-namespacing

## Status

Accepted. This is a decision to defer, not to do nothing forever — it records explicit trigger
conditions for revisiting rather than leaving the question open-ended.

## Context

`src/sdata_core-commands.adb` is 1,808 LOC (up from 617 at the crate's first milestone baseline);
`commands.ads` is a flat 406-line, 31-entry public spec. It is now the single largest body in the
crate, ahead of `evaluator.adb` (1,199) and larger than `table.adb` was *before* its own decomposition
(ADR-0007, ~1,210-1,269 LOC). The 2026-07-23 milestone audit (M2-FOWLER-2,
`.ssd/milestones/2026-07-23-post-decomposition-baseline/skeptic-before.md`) flagged this growth
trajectory as worth a namespacing decision before it compounds further, given the crate has a proven,
low-risk in-house playbook for exactly this situation (ADR-0007's `Table` decomposition).

The same audit round also considered, and explicitly closed as a non-goal, a *code* extraction across
the three largest procedures in this file (`Execute_AGGREGATE`/`Execute_TRANSPOSE`/`Execute_STATS`,
M2-FOWLER-1) — full inspection showed their validation, schema-building, and emit logic are genuinely
different per command, not copy-pasted, and everything actually shareable between them had already been
extracted by a prior refactor series (`refactor/r1-commit-reshaped-table` / `r2-group-boundaries` /
`r4-by-output-helpers`, PRs #75-77, 2026-07-06/07 — undiscovered by this crate's own SSD tracking until
this audit). That closure is directly relevant here: `commands.adb`'s size is *not* evidence of
duplication the way `table.adb`'s was — it's the sum of legitimately distinct command implementations
living in one file. This ADR is about file organization, independent of that finding.

**Reproduced here rather than only cross-referenced**, since the milestone audit that found it
(`.ssd/milestones/2026-07-23-post-decomposition-baseline/`) is a local working directory excluded from
version control (`.gitignore`) and won't travel with the repo: the R4 commit (`c94a1c0`, 2026-07-07)
extracted `Add_By_Output_Columns`/`Set_By_Output_Values` and adopted them in `TRANSPOSE`/`STATS`, but
explicitly left `AGGREGATE` alone, reasoning that `AGGREGATE`'s `Build_Descriptors`/`Emit_Group`
interleave BY columns and function-result columns into one flattened `Out_Desc` list — positionally
distinct from `TRANSPOSE`/`STATS`'s simpler "BY columns first, then everything else" schema — such that
"adopting the positional helpers there would contort that design for no gain." The 2026-07-24 audit
independently reached the same conclusion (before finding that commit) when evaluating a full
`Reshape_Command` template across all three commands. This reasoning is now also recorded as an in-code
comment directly above `Execute_AGGREGATE` in `commands.adb` (added alongside this ADR), so a future
reader hits it without needing `git blame`.

## Decision

**Do not split `SData_Core.Commands` now.** Unlike `Table` at the time of ADR-0007 — which had ~7
actually-entangled responsibilities sharing one pile of package-level mutable state (spill,
sort, schema, values, output, BY-group, filter map) — `Commands`'s size comes from many independent,
non-interacting command implementations that happen to share one file. There is no entanglement to
untangle, no compiler-enforced isolation to gain, and no consumer-facing coupling problem. Splitting
now would be organizational tidiness, not a fix for a real defect — the same "cost exceeds benefit"
judgment this milestone already made for M2-FOWLER-1.

**Revisit when any of these trigger conditions is met:**

1. `commands.adb` exceeds **~2,500 LOC** (a further ~40% growth from today), or
2. A **fourth** reshape-style command (in the shape of `AGGREGATE`/`TRANSPOSE`/`STATS`) is added,
   giving a natural, non-speculative grouping boundary to split along, or
3. Any two command groups develop **actual shared state or coupling** beyond the common
   `Config.Runtime`/`Table` dependencies every command already has — i.e., the `Table` god-package
   symptom, not the `Commands` file-size symptom, reappearing here.

**Candidate split, if triggered:** a child-package-per-family structure, mirroring the pattern already
proven in this crate for `SData_Core.Evaluator`'s per-function-family children
(`Aggregate_Fns`/`Numeric_Fns`/`String_Fns`/etc.) — e.g. `SData_Core.Commands.Reshape` for the
AGGREGATE/TRANSPOSE/STATS family, with unrelated commands (`USE`/`SAVE`/`FPATH`/`OPTIONS_*`/etc.)
staying in the parent or splitting along their own natural groupings at that time. This is a candidate,
not a commitment — the actual boundary should be decided against the codebase shape at the time a
trigger fires, not against today's shape.

## Consequences

**Positive**

- Avoids a refactor with no defect behind it — the direct lesson of this same milestone's M2-FOWLER-1
  closure, applied consistently rather than special-cased.
- Trigger conditions are concrete and checkable at the next milestone audit, rather than "watch this
  file and feel uneasy about it" recurring indefinitely as a vague concern.

**Negative**

- `commands.adb` remains the largest body in the crate for now, and will keep growing as new commands
  are added — a new contributor's first impression of the file is "big," even though no individual
  procedure in it is unmanageable in isolation.

## Non-goals

- Splitting `Table.Name_Vectors`/`Sort_Criteria_Array`'s public forms onto `Column_Name` — unrelated,
  tracked separately as J1's public tail (ADR-0007's Non-goals; scheduling tracked in this milestone's
  refactor-plan.md item R4).
- Any code change to `Execute_AGGREGATE`/`Execute_TRANSPOSE`/`Execute_STATS` — closed as a non-issue by
  M2-FOWLER-1 this same milestone.

## Related

- ADR-0007 — the `Table` decomposition this ADR deliberately does *not* replicate here, and why the
  two situations differ (entangled responsibilities vs. file-size accumulation).
- `src/sdata_core-commands.adb`, the design-note comment directly above `Execute_AGGREGATE` — the
  committed, permanent record of why `AGGREGATE` diverges from `TRANSPOSE`/`STATS`'s shared BY-output
  helpers. Read this first; it doesn't require repo-local `.ssd/` state.
- Commit `c94a1c0` (R4, 2026-07-07) — the original reasoning, in git history.
- `.ssd/milestones/2026-07-23-post-decomposition-baseline/skeptic-before.md` and `refactor-plan.md`
  (items M2-FOWLER-1, M2-FOWLER-2, M2-UB-1, R3) — the full milestone analysis, if present locally;
  this is a gitignored working directory, not guaranteed to exist in every checkout.
