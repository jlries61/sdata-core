---
id: ADR-0023
title: "Virtual-array element writes dispatch LET/SET by the resolved constituent's storage class, not the array-level flag"
status: Accepted
date: 2026-09-04
related:
  - ADR-0010-set-let-storage-class-hard-error.md
  - ADR-0012-scalar-array-storage-class-hard-error.md
  - ADR-0014-array-element-reference-hard-error.md
  - ADR-041 (../../../sdata/doc/adrs.md) — subscripted-column auto-detection
  - jlries61/sdata-core#118
---

# ADR-0023: Virtual-array element writes dispatch LET/SET by the resolved constituent's storage class, not the array-level flag

## Status

Accepted.

## Context

GitHub issue [jlries61/sdata-core#118](https://github.com/jlries61/sdata-core/issues/118): a
virtual array (`ARRAY V A B ...`) can alias constituents of different storage classes — some
permanent (table columns), some genuine temporary (`SET` variables). Nothing prevents constructing
one; `Define_Array` maps arbitrary existing variable names. But no element of *any* virtual array
can currently be written through array syntax if that element's constituent happens to be a genuine
temporary:

- `SData_Core.Variables.Define_Array` hardcodes `Arr_Def.Is_Temporary := False` unconditionally for
  every virtual array — "Virtual arrays are always permanent aliases" — because there is no single
  correct array-wide answer once constituents can differ.
- sdata's `Execute_Array_Assignment` (`sdata-interpreter-execute_assignment.adb`) gates `LET`/`SET`
  on `Is_Temporary_Array (Var_Name)` — the array-level flag — once per statement, before resolving
  which constituent a given index actually names. For any virtual array this flag is always `False`,
  so `SET V(i)` is rejected unconditionally for every element, and `LET V(i)` is let through
  unconditionally regardless of whether the target constituent is actually temporary.
- `SData_Core.Variables.Set_Array_Element` dispatches the same way, on `Arr_Def.Is_Temporary` (also
  always `False` for virtual arrays), so even a `SET` that got past a hypothetical relaxed Layer-1
  check would still call `Set_Permanent`, not `Set_Temporary`.

The net effect: `LET V(2)` (where `V(2)` aliases temporary `B`) reaches `Set_Permanent`, which
raises ADR-0010's hard error citing `B` by its bare name — not `V(2)`, what the user actually typed.
`SET V(2)` never reaches Layer 2 at all; Layer 1 rejects it for every virtual array unconditionally.
There is no way to write a temporary constituent through array-element syntax; the user must drop
out of array notation and assign the bare name directly.

A **real** (`DIM`'d) array is not affected by any of this: `DIM ... /TEMP` creates the whole array
as one storage class, so the array-level `Is_Temporary` flag is correct and uniform by construction
for every element. Virtual arrays are the only case in this codebase where "one flag, many
independently-defined constituents" can diverge — because `ARRAY` aliases pre-existing names instead
of creating new ones under a single declaration.

Three resolutions were on the table (per the issue):

1. Validate at `ARRAY` definition time that all constituents share one storage class, rejecting a
   mixed-class virtual array outright.
2. Dispatch per-element: resolve each constituent's *own* class at write time and route to
   `Set_Temporary`/`Set_Permanent` accordingly.
3. Collapse the `LET`/`SET` distinction entirely at the element level — either verb means "write
   this value," inferring the correct underlying call.

## Decision

**Option 2, precisely** — with the existing `LET`-means-permanent / `SET`-means-temporary
verb-correctness rule (ADR-0010) preserved, just evaluated per element instead of per array:

1. **`SData_Core.Variables` gains a new public function**:

   ```ada
   function Array_Element_Is_Temporary (Name : String; Index : Integer) return Boolean;
   ```

   For a `Real_Array`, returns the array-level `Is_Temporary` flag (unchanged — still correct and
   uniform). For a `Virtual_Array`, resolves the constituent at `Index` and returns whether it is a
   genuine temporary: `Temp_Symbols.Contains` **and not** `Is_Held` — the same "genuine temporary"
   definition `Set_Permanent`'s own ADR-0010 check uses, so a held-permanent variable's
   `Temp_Symbols` carry-over mirror (see `Reset_PDV_Non_Held`) does not misdispatch a write to it as
   temporary. Raises `SData_Core.Script_Error` under the same three conditions as
   `Get_Array_Element`/`Set_Array_Element` (ADR-0014): array undefined, index out of the array's
   declared range, or (virtual arrays only) resolved offset exceeds the registered constituent
   count.

2. **`Set_Array_Element`'s dispatch** (currently `if Arr_Def.Is_Temporary then Set_Temporary else
   Set_Permanent`) is replaced with per-`Kind` logic: `Real_Array` keeps the array-level flag;
   `Virtual_Array` checks the resolved constituent's own class (the same primitive the new public
   function uses — factored into one private helper so the two call sites cannot drift).

3. **sdata's `Execute_Array_Assignment`** replaces its array-level `Is_Temporary_Array (Var_Name)`
   gate with the new per-element `Array_Element_Is_Temporary (Var_Name, Index)`, evaluated for each
   index in a single-index, slice, or list assignment — not once per statement. This both fixes the
   wrong-verb rejection (a virtual array's temporary elements become writable via `SET`, its
   permanent elements remain `LET`-only, exactly mirroring bare-scalar `LET`/`SET` semantics for that
   constituent) and lets the error message name what the user actually typed (`V(2)`) instead of the
   resolved constituent (`B`).

**Option 1 is rejected**: mixed-class virtual arrays are not the defect — the dispatch bug is. Issue
#118 itself frames "nothing prevents constructing" a mixed-class array as existing, presumably
intentional capability (aliasing arbitrary existing variables by number is the whole point of
`ARRAY`, per design.md and ADR-041); forbidding it would remove functionality to route around a bug
that has a direct, narrower fix.

**Option 3 is rejected**: collapsing `LET`/`SET` at the element level would special-case virtual
array elements out of ADR-0010's project-wide "hard error, not implicit conversion" philosophy for
no offsetting benefit — per-element dispatch (option 2) already lets both verbs work correctly, each
on the elements it is supposed to work on; a script that writes `LET V(2)` on a temporary element
should still fail loudly and say "use SET," exactly as bare `LET B = ...` already does today. Making
element writes verb-agnostic would be a second, inconsistent house style for the identical
underlying operation depending only on whether it goes through array syntax.

### Atomicity for slice/list assignment

`Execute_Array_Assignment` handles single-index, slice (`V(Lo:Hi)`), and list (`V(i,j,k)`) forms.
Moving the per-element check inside the write loop (rather than once before it) means a slice or
list spanning constituents of mixed class must not partially write some elements before raising on
a later one. The implementation validates every index in the target set *before* writing any of
them — consistent with the array's own bounds check today, which likewise runs to completion before
any write begins.

## Rationale

- Directly extends ADR-0010's verb-correctness rule to the one place it wasn't actually enforced
  correctly — at the element level of a virtual array — rather than introducing a new rule.
- No existing public signature changes; the fix is a new function plus an internal dispatch
  correction. `Set_Array_Element`'s and `Get_Array_Element`'s signatures, and every existing call
  site in both consumers, are untouched.
- Symmetric with `Array_Element_Is_Temporary`'s natural counterpart already existing for the
  array-wide case (`Is_Temporary_Array`) — this is the missing per-element sibling, not a new
  concept.

## Consequences

**Positive**

- Closes #118: every virtual-array element becomes writable through array syntax with the verb that
  matches its actual constituent, matching what bare-name assignment to that same constituent
  already allows.
- Error messages for the rejected verb now name what the user typed (`V(2)`), not the resolved
  constituent (`B`).
- Purely additive to the public API surface (one new function); no consumer call site requires a
  change to keep building.

**Negative**

- `Execute_Array_Assignment`'s per-statement LET/SET gate becomes a per-index gate, changing where
  and how often the check runs and its complexity from O(1) to O(n) in the slice/list case — a
  matched cost against the atomicity guarantee above.
- Any existing consumer test asserting today's error text ("SET statement cannot modify individual
  elements of permanent or virtual array") for a virtual array must be updated: that message is now
  only correct for a virtual array whose *targeted element* is genuinely permanent, not for the
  array as a whole.

## Alternatives Rejected

See "Decision" above (options 1 and 3, and the rationale for rejecting each).

## Related

- ADR-0010 (`set-let-storage-class-hard-error`) — the verb-correctness rule this decision extends
  per-element instead of per-array.
- ADR-0012 (`scalar-array-storage-class-hard-error`), ADR-0014
  (`array-element-reference-hard-error`) — the `Script_Error` convention and existing
  `Get_Array_Element`/`Set_Array_Element` validation this decision reuses without modification.
- `../../../sdata/doc/adrs.md` ADR-041 — subscripted-column auto-detection, background on how
  virtual arrays acquire their constituents.
- `jlries61/sdata-core#118` — the issue this decision resolves.
