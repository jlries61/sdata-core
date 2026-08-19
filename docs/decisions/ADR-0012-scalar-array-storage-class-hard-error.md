---
id: ADR-0012
title: "LET/SET/DIM scalar<->array redefinition is a hard error, extending ADR-0010's precedent"
status: Accepted
date: 2026-08-18
related:
  - ADR-0010-set-let-storage-class-hard-error.md
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md
---

# ADR-0012: LET/SET/DIM scalar<->array redefinition is a hard error, extending ADR-0010's precedent

## Status

Accepted.

## Context

sdata's 2026-08-13 design-vs-implementation re-audit (finding **PC-2**,
`part-c-data-model-variables.md`) found that `SData_Core.Variables` enforces
storage-class immutability across *scalar* storage classes (temporary vs.
permanent, per **ADR-0010**) but not across the *scalar vs. array* boundary:

- `Set_Permanent` (`LET`) and `Set_Temporary` (`SET`) check `Table.Has_Column`
  and `Temp_Symbols.Contains` respectively, but never check
  `Array_Symbols.Contains` — so `LET Q = 99` on an existing array `Q` silently
  creates a same-named scalar PDV/temp-symbol entry alongside the untouched
  `Array_Symbols` entry, rather than erroring or replacing.
- `Dim_Array` (`DIM`) checks `Array_Symbols.Contains` for array-kind conflicts
  (virtual vs. real, temporary-status change) but never checks whether the
  name already exists as a scalar (`Table.Has_Column`, `Temp_Symbols`, or
  `PDV_Index`) — so `DIM S(1 TO 3)` on an existing scalar `S` has the same
  problem in the opposite direction.

Design.md §3.5's Redefinition Rules already state this as two unconditional
bullets ("Existing arrays may not be redefined as scalar variables unless
first deleted"; "Existing scalar variables may not be redefined as arrays
unless first deleted") — this is a genuine implementation gap against an
existing documented rule, not a new rule being introduced.

The resulting shadow state is not merely inert: `PRINT Q` after `LET Q = 99`
continues to return the array's old element values (`Array_Symbols` still
resolves `Q` as an array to the print/lookup path), not the new scalar —
the scalar becomes silently unreachable through normal syntax while still
occupying a PDV/temp-symbol slot.

This is the same defect *shape* ADR-0010 closed for temporary-vs-permanent
redefinition: an assignment/declaration verb silently crossing a storage-class
boundary instead of erroring. ADR-0010's own "Consequences" section already
flagged the array-element precedent (`Execute_Array_Assignment` in sdata
already raises `Script_Error` for wrong-direction array-*element* access) as
the model scalar assignment was brought into line with — this ADR closes the
remaining gap: the array-*name* level, at the point of `LET`/`SET`/`DIM`
rather than element access.

## Decision

Extend ADR-0010's hard-error principle to the scalar/array boundary:

1. **`Set_Temporary` (`SET`) and `Set_Permanent` (`LET`)** each gain an
   `Array_Symbols.Contains (Upper_Name)` check, raising
   `SData_Core.Script_Error` before any assignment occurs — mirroring the
   existing storage-class checks immediately above them in the same
   procedures, same message shape. As implemented, the remedy directs the
   user to `DROP` (the only deletion primitive that actually frees an
   array's name in both the virtual and real case, per this ADR's own
   completion of `Execute_DROP` below):

   > `"<VERB> cannot redefine array """ & Upper_Name & """; use DROP
   > """ & Upper_Name & """ to delete the array first, then <VERB> it to
   > create a <temporary|permanent> variable of the same name"`

2. **`Dim_Array` (`DIM`)** gains the symmetric check for an existing *scalar*
   of the same name. As implemented, this checks only `Table.Has_Column`
   and `Temp_Symbols.Contains` — **not** `PDV_Index` directly, despite this
   ADR's original draft proposing the latter (to catch a computed `LET`
   temporary not yet flushed to a real column). Implementation surfaced a
   real collision: `Register_Subscripted_Columns` (ADR-041) calls
   `Dim_Array` to re-register an `AGGREGATE` outvar's new array shape
   immediately after a table swap, at a point where `PDV_Index` can still
   hold a stale entry for the *old* scalar shape — a `PDV_Index` check
   rejected this legitimate internal call the same as it would an ordinary
   user `DIM` colliding with a live scalar (caught by the existing
   regression test `aggregate_array_resize_warn.cmd`, which requires this
   exact resize to succeed with its own documented warning, not an error).
   `Table.Has_Column`/`Temp_Symbols.Contains` are the two storage classes
   that stay meaningful across a table swap and are, not coincidentally,
   exactly the two conditions `Set_Temporary`/`Set_Permanent`'s own checks
   test in the other direction — the implementation is more symmetric for
   having dropped `PDV_Index`, not less correct.

3. **Exception type is `Script_Error`, not `Program_Error`.** `Dim_Array`'s
   pre-existing virtual-vs-real array conflict check (line ~614,
   `"Cannot redefine virtual array ... as real array with DIM."`) currently
   raises `Program_Error` — an inconsistency with the `Script_Error`
   convention this ADR and ADR-0010 both use for user-triggerable,
   well-formed-script rejections. This ADR does **not** change that
   pre-existing line (it is PC-3's territory, out of scope here per the
   sdata audit's own tier split) but the *new* scalar<->array checks added
   by this ADR use `Script_Error` throughout, matching ADR-0010, not the
   older `Program_Error` local to `Dim_Array`. A future PC-3 fix should
   reconcile the virtual/real case to the same convention rather than the
   reverse.

No new syntax or modifier is introduced. Explicit, deliberate conversion
remains possible via existing primitives: drop or resize the array to zero
extent (real arrays; mechanism TBD by coder — `DIM` has no explicit "delete"
form today, only resize) or `Undefine_Virtual_Array` (virtual arrays, already
exposed) before redefining the name as a scalar; `DROP`/re-`DIM` for the
reverse direction.

## Rationale

- Same category of decision as ADR-0010, same author intent (design.md's
  redefinition rules), same failure mode (silent shadow state instead of a
  clear error) — reusing the decision and its message-shape convention keeps
  the codebase's error vocabulary consistent rather than inventing a second
  house style for what is, functionally, the same kind of mistake.
- `Script_Error` (not `Program_Error`) is required for the new checks because
  it is the exception the sdata interpreter's top-level dispatch loop
  specifically catches and reports as a clean, continuable user error
  (`sdata-interpreter.adb`'s `when E : Script_Error | SData_Core.Script_Error`
  handler) — `Program_Error` falls through to the generic `others` handler,
  which still produces a reasonable message at today's single call site but
  is the wrong semantic signal for a well-formed-script rejection versus an
  internal-invariant violation.

## Consequences

**Positive**

- Closes PC-2: `LET`/`SET`/`DIM` can no longer create an unreachable shadow
  variable across the scalar/array boundary.
- Consistent, single house style for storage-class redefinition errors across
  all boundaries this project distinguishes (temporary/permanent per
  ADR-0010; scalar/array per this ADR).

**Negative**

- A script that relied on the old silent-shadow behavior (almost certainly
  unintentional, per the audit's own characterization — "the result actively
  misbehaves") now errors instead. No test, doc passage, or example script
  was found exercising this as an intentional feature (same verification
  approach ADR-0010 used); coder should re-confirm with a repo-wide grep
  before closing this workstream's implementation task, mirroring ADR-0010's
  own diligence.
- `Dim_Array`'s pre-existing `Program_Error` inconsistency (item 3 above) is
  now more visible by contrast (two `Script_Error` checks added next to one
  `Program_Error` check for a related condition) but is explicitly left
  unresolved here — reconciling it is out of scope for this workstream (see
  sdata's `.ssd/features/audit-2026-08-13-tier1-remediation/00-brief.md`
  "Out of scope").

## Alternatives Rejected

- **Auto-delete-and-replace** (silently drop the old array/scalar and create
  the new one) — rejected for the same reason ADR-0010 rejected auto-convert:
  it's a worse UX than a clear error for what is very likely a naming
  mistake, and (for the array case specifically) auto-deleting a real array's
  columns as a side effect of an unrelated-looking `LET` statement is exactly
  the kind of surprising, hard-to-audit-in-a-diff behavior ADR-0010 explicitly
  moved away from.
- **Leave `Program_Error` for the new checks too**, matching `Dim_Array`'s
  existing local convention instead of ADR-0010's project-wide one —
  rejected because `Program_Error` is caught less specifically at the
  interpreter's dispatch loop and semantically signals "should not happen"
  rather than "user wrote something invalid"; ADR-0010's convention is the
  newer and more deliberate one of the two.

## Related

- ADR-0010 (`set-let-storage-class-hard-error`) — the precedent this decision
  extends.
- sdata `.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md`
  finding PC-2.
- sdata `.ssd/features/audit-2026-08-13-tier1-remediation/00-brief.md` and
  `01-architect.md` — the workstream implementing this decision.
- design.md §3.5 "Redefinition Rules" (sdata's authoritative language spec).
