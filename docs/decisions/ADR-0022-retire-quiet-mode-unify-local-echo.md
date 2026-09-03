---
id: ADR-0022
title: "Retire SData_Core.Config.Quiet_Mode; SData_Core.IO.Local_Echo is the sole console-output-suppression flag"
status: Accepted
date: 2026-08-31
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-e-io-operators-implementation-notes.md
  - ../../../sdata/.ssd/features/pe4-echo-quiet-mode-unify/00-brief.md
  - ../../../sdata/.ssd/features/pe4-echo-quiet-mode-unify/01-architect.md
  - ../../../sdata/.ssd/features/pe4-echo-quiet-mode-unify/02-systems-designer.md
---

# ADR-0022: Retire `SData_Core.Config.Quiet_Mode`; `SData_Core.IO.Local_Echo` is the sole console-output-suppression flag

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PE-4**, `part-e-io-operators-implementation-notes.md`)
found that sdata's design.md documents `-q` as suppressible-and-reversible: *"-q: Suppress writing
of console output to standard output (can be undone with ECHO ON)."* This was empirically false.
`-q` set `SData_Core.Config.Quiet_Mode := True`; the `ECHO` command's `Set_Local_Echo` only ever
touched `SData_Core.IO`'s separate, private `Local_Echo` flag. The two flags were independent —
`ECHO ON` had no code path to `Quiet_Mode` at all.

Investigating the fix's true scope (rather than patching the 3 lines PE-4 itself cited —
`sdata_core-io.adb`'s `Put`/`Put_Line`/`New_Line`) found `Quiet_Mode` referenced in **21 places
across all three repos** (sdata-core, sdata, data-vandal): 1 declaration, 2 writes (each
consumer's `-q` parsing), 3 "core gate" sites (the ones PE-4 cited), and **14 more read sites**
splitting into two structurally different categories:

- **7 sites** wrap `SData_Core.IO.Put`/`Put_Line` calls, which already internally gate on
  `Local_Echo and then not Quiet_Mode` — these outer checks are provably redundant, existing only
  to skip constructing a message string.
- **7 sites** wrap `SData_Core.IO.Put_Line_Error` calls — `Put_Line_Error`/`Put_Error` have **no**
  internal gating (unconditional writes to `Standard_Error`, by design). For these, the outer
  `Quiet_Mode` check was the *sole* suppression mechanism, and it suppressed ODF/OOXML import
  warnings under `-q` — directly contradicting the man page's own documented `-q` contract
  ("Quiet mode: suppress console output. Error messages are still written to standard error.").

design.md §6.1 already frames `-q` and `ECHO OFF` as two paths to the same suppressed state
("...unless the *-q* flag or *ECHO OFF* is in effect") — the two-flag implementation never matched
that framing; `Quiet_Mode` living in `SData_Core.Config` (documented package-level as "startup
configuration... constant across the lifetime of the process") while `Local_Echo` lives in
`SData_Core.IO` with an explicit runtime `Set_` procedure is itself a sign the two were never
meant to be independent, permanent concepts.

## Decision

`SData_Core.Config.Quiet_Mode` is removed. `SData_Core.IO.Local_Echo` becomes the sole
console-output-suppression state, exposed via a new public accessor,
`SData_Core.IO.Is_Local_Echo return Boolean` (naming matches the existing `Set_Interactive`/
`Is_Interactive` accessor-pair convention). `-q` in both consumers becomes
`SData_Core.IO.Set_Local_Echo (False)` at CLI-parse time — literally "start the session with
`ECHO OFF`" — making the documented "`-q` can be undone with `ECHO ON`" claim true, since `ECHO
ON` already correctly flips the one flag both mechanisms now share.

**Decision — the 7 redundant sites (wrapping `Put`/`Put_Line`) switch their outer condition from
`Quiet_Mode` to the new `Is_Local_Echo` accessor**, preserving the existing micro-optimization
(skip string construction when suppressed) rather than deleting the outer check and relying
purely on `Put_Line`'s own internal gate — keeps the diff mechanical, one condition source
swapped per site, no structural change.

**Decision — the 7 sites gating `Put_Line_Error` (ODF/OOXML import warnings) lose their outer
check entirely**, becoming unconditional like every other `Put_Line_Error` call in the codebase.
This is a deliberate, accepted behavior change: these warnings will now print under `-q` where
they previously didn't. It corrects an independent, pre-existing inconsistency with `-q`'s own
documented contract (found during this investigation, not introduced by it) — closing it here,
while every one of these call sites is already being touched for the unification, is strictly
better than leaving a known doc-vs-code gap for a future workstream to rediscover from scratch.

## Consequences

**Breaking public API change**, per this crate's own stability contract: `Quiet_Mode` was a bare
public mutable field both consumers referenced directly. Both consumers' dispatch sites are
updated in this same coordinated change (sdata: `sdata_main.adb`'s `-q` parsing +
`sdata-interpreter.adb`'s 2 redundant sites; data-vandal: `data_vandal_main.adb`'s `-q` parsing +
`execute_vandalize.adb`'s 1 redundant site).

`data-vandal` has no `ECHO` command — its `-q` stays permanently one-way in practice (nothing ever
calls `Set_Local_Echo (True)` there), so this is a pure plumbing swap with zero net behavior
change for that consumer, confirmed against its own existing `tests/quiet.cmd` regression test
(asserts empty output under `-q`; unaffected by this change since it exercises only a Category-A
site on a CSV fixture, not the Category-B ODF/OOXML path).

The `Redirected`/`OUTPUT`-file write path (§6.1's separately-verified-true claim that an `OUTPUT`
file receives console output unconditionally, even under `-q`) is structurally untouched — it is
an earlier, independent `if Redirected then ... end if` block in `Put`/`Put_Line`/`New_Line`,
outside the `Local_Echo`-gated block this change modifies.

Version bump: minor (breaking removal of a public symbol, not additive), per this crate's own
`§Versioning` convention and matching the weight of comparable prior behavior-change ADRs this
session (ADR-0019, ADR-0021).

## Alternatives Rejected

Patching only the 3 sites PE-4 itself cited (`Put`/`Put_Line`/`New_Line`'s internal gate) —
rejected once investigation showed 14 more sites shared the same root cause, 7 of which
(Category B) don't even go through the internal gate at all; a narrow patch would have made
`ECHO ON` inconsistently override `-q` depending on which message class was involved, arguably a
worse state than the current uniform (if wrong) one-way suppression. Leaving `Quiet_Mode` in place
alongside a new `Is_Local_Echo`-based path (two flags, one now redundant) — rejected as
introducing exactly the kind of dead/parallel state this ADR exists to eliminate. Softening
design.md's claim instead of fixing the code — the user's explicit choice, made with the full
scope visible (not the narrow 3-line framing PE-4's own citation suggested).
