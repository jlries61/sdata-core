---
id: ADR-0015
title: "DIM/ARRAY array-kind replacement follows design.md symmetrically: DIM may replace a virtual array; ARRAY may not replace a real array"
status: Accepted
date: 2026-08-22
related:
  - ADR-0012-scalar-array-storage-class-hard-error.md
  - ADR-0014-array-element-reference-hard-error.md
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md
  - ../../../sdata/.ssd/features/pc3-array-kind-replacement/00-brief.md
---

# ADR-0015: `DIM`/`ARRAY` array-kind replacement follows design.md symmetrically

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PC-3**, `part-c-data-model-variables.md`) found that `DIM`
refuses to replace an existing **virtual** array with a real one, contradicting design.md §3.5:

> *"Virtual array may be replaced by permanent/temporary array using DIM (no effect on former
> constituent variables)."*

`Dim_Array` (`sdata_core-variables.adb:681-682`) raises unconditionally:

```ada
if Existing_Def.Kind = Virtual_Array then
   raise Program_Error with "Cannot redefine virtual array '" & Upper_Name & "' as real array with DIM.";
```

Investigating this surfaced the **mirror-image** bug, not covered by the original audit: `ARRAY`
(`Define_Array`, same file, lines 474-509, both overloads) has **no check at all** for the opposite
direction, and design.md's own `ARRAY` command-reference row requires one:

> *"If an actual array with the name specified already exists then the command shall fail with an
> error message. If a virtual array with the name specified exists then the new definition shall
> replace the old one."*

`Define_Array` unconditionally does `Array_Symbols.Replace`/`Insert` regardless of the existing
entry's `Kind`, silently overwriting a real array's registration and **orphaning its data columns**
— they remain in the table (still visible via `NAMES`, still occupying storage) but become
permanently unreachable via array syntax, since `Array_Symbols[name]` now points at the virtual
definition instead. This is worse than PC-3's original finding: not just a wrong-direction
rejection, but silent state corruption with no error at all.

The user, informed of this second finding mid-investigation, chose to fold both directions into one
workstream rather than filing the `ARRAY`-side bug separately (see `00-brief.md`) — both are the
same underlying "missing/backwards kind check" defect on the same virtual/real array boundary.

## Decision

1. **`Define_Array`** (both overloads) gains a guard: if `Array_Symbols.Contains (Upper_Name)` and
   the existing entry's `Kind = Real_Array`, raise `SData_Core.Script_Error` before either `Replace`
   or `Insert` runs. Message: `"Cannot redefine array '<NAME>': an array already exists with that
   name. DROP it first, then use ARRAY to create a virtual array of the same name."` — matching the
   "DROP it first" remedy phrasing already established for the analogous PC-2/ADR-0012 scalar/array
   conflict messages, so the whole family of "name already means something else" errors reads
   consistently across this codebase.
2. **`Dim_Array`**'s `if Existing_Def.Kind = Virtual_Array then raise ...` branch is removed
   entirely (not replaced with different logic) — falling through to the function's existing
   unconditional tail (`Create_Real_Elements (Arr_Def)` then `Array_Symbols.Replace`) is sufficient.
   A virtual array owns no table columns of its own (its "storage" is its constituent variables,
   which this change does not touch), so there is nothing to drop or reconcile; `Create_Real_Elements`
   already tolerates being called for a name with no prior real-array shape (that's exactly what it
   does for a brand-new `DIM`), and correctly creates the new array's own columns
   (`Get_Real_Var_Name`-generated names, distinct from the former constituents' own names, so no
   collision is possible).
3. **`Dim_Array`'s adjacent temp-status-change raise** (line 686, `"Cannot change temporary status of
   existing real array"`) — not itself a defect (the 2026-08-13 audit confirmed this one already
   fails correctly) — is also converted from `Program_Error` to `SData_Core.Script_Error` in the same
   change, matching ADR-0012/ADR-0014's convention, since this workstream is already editing the
   surrounding lines and leaving one of three sibling raises on the old exception type would be a
   step backward for consistency, not a neutral no-op.
4. **`Register_Subscripted_Columns`'s (ADR-041) indirect, unguarded call into `Dim_Array`** during
   `USE`-time auto-detection is deliberately **not special-cased**. If a virtual array happens to
   share a base name with a dataset's `base(n)`-shaped columns, this decision's point 2 change
   applies uniformly: the virtual array is replaced by the newly loaded real array, exactly as a
   direct user `DIM` call now would be. This is judged a natural, correct consequence of point 2 —
   not a new problem requiring deferral — because: (a) it carries none of the ARRAY-side's data-loss
   risk (the former constituents remain independently valid, untouched variables; nothing is
   orphaned); (b) today, this same collision does not silently corrupt anything either — it crashes
   `USE` with an uncaught `Program_Error` (`Register_Subscripted_Columns` has no local exception
   handler around its `Dim_Array` call), so removing the crash in favor of the documented replacement
   behavior is a strict improvement, not a new risk. This is a distinct question from the already-filed,
   deliberately-still-open **sdata-core#117** (a bare column colliding with matching subscripted
   columns of the *same* load — a same-load internal-consistency question with no design.md guidance
   either way), which this decision does not touch or attempt to resolve.

## Rationale

- Both directions of design.md's stated rule are unambiguous and already written down — this is a
  "make the code match the already-agreed spec" fix, not a design negotiation, unlike PC-1's
  `Program_Error`-vs-`Script_Error` choice which had no prior documented answer.
- The `ARRAY`-side fix closes a genuine data-corruption path (orphaned columns with no error), which
  is more severe than the audit's own framing of PC-3 as a "restriction is backwards" finding.
- Reusing the "DROP it first" remedy phrasing keeps the whole family of storage/kind-conflict error
  messages (PC-2's scalar/array guard, this one's array/array-kind guard) consistent for a script
  author encountering any of them.

## Consequences

**Positive**

- Closes PC-3 exactly as documented, in both directions.
- Removes a real data-loss bug (`ARRAY` silently orphaning a real array's columns) that the original
  audit did not catch.
- `Dim_Array`'s three raises are now uniformly `SData_Core.Script_Error` (only the unrelated
  lower/upper-bound argument check, out of scope per the brief, remains `Program_Error`).

**Negative**

- `Dim_Array` gains a new, consumer-visible success path (replacing a virtual array no longer
  raises) — any caller that relied on the raise (none found; see `01-architect.md`'s call-site
  review) would need to change. `Define_Array` gains a new, consumer-visible failure path (replacing
  a real array now raises where it silently succeeded before) — this is the point of the fix, but is
  still a real behavior change for any script that happened to rely on the old silent-overwrite
  (none found in the existing test suite, see `01-architect.md`'s Risk Assessment).

## Alternatives Rejected

- **Reject `Register_Subscripted_Columns`'s indirect collision case explicitly** (e.g., a special
  "USE-time DIM never replaces a virtual array" carve-out) — rejected: would reintroduce the exact
  asymmetry this ADR closes, just relocated to a different call site, for no documented reason;
  design.md does not distinguish "DIM called directly" from "DIM called by USE's auto-detection."
- **Leave `Dim_Array`'s temp-status-change raise as `Program_Error`** (touch only the two findings
  named by the audit) — rejected: cheaper diff, but leaves one of three sibling checks in the same
  function on the pre-ADR-0012 convention for no reason other than "the audit didn't name it,"
  repeating the exact inconsistency ADR-0012/ADR-0014 already spent effort closing elsewhere.

## Related

- ADR-0012 (`scalar-array-storage-class-hard-error`), ADR-0014
  (`array-element-reference-hard-error`) — the `Script_Error` convention this decision extends.
- sdata `.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md` finding
  PC-3.
- sdata-core issue #117 — a related but distinct, still-open ADR-041 question this decision does
  not resolve.
- sdata `.ssd/features/pc3-array-kind-replacement/` — the workstream implementing this decision.
