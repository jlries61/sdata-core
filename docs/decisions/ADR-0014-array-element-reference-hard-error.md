---
id: ADR-0014
title: "Array-element references (read and write) raise Script_Error, not Program_Error, on invalid reference"
status: Accepted
date: 2026-08-21
related:
  - ADR-0012-scalar-array-storage-class-hard-error.md
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md
  - ../../../sdata/.ssd/features/pc1-array-element-read-error/00-brief.md
---

# ADR-0014: Array-element references (read and write) raise `Script_Error`, not `Program_Error`, on invalid reference

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PC-1**, `part-c-data-model-variables.md`) found that
`SData_Core.Variables.Get_Array_Element` silently returns a missing value for three invalid-reference
cases that its write-side counterpart, `Set_Array_Element`, already correctly rejects:

1. The array name doesn't exist at all.
2. The index falls outside the array's declared `Start_Index .. End_Index`.
3. (Virtual arrays only) the computed offset exceeds `Constituents.Length` — an internal-invariant
   case the code's own comment says "should not happen if array correctly defined," not a plain
   user typo, but still currently silent on read.

design.md states, in two places (§2.5 and §3.3, near-verbatim), that references to non-existent
array elements "shall fail with an error message" — unqualified as to read vs. write. The write
path already does this; the read path doesn't.

Fixing the read path to raise (rather than return missing) requires choosing an exception type.
`Set_Array_Element`'s three existing raises (`sdata_core-variables.adb`, lines ~767, ~774, ~786)
all use `Program_Error`. But this project's own established convention since **ADR-0010**
(temporary/permanent storage-class hard error) and **ADR-0012** (scalar/array storage-class hard
error, which explicitly named `Dim_Array`'s pre-existing `Program_Error` use for an unrelated
conflict check as an inconsistency *not* to be propagated into new code) is: `Script_Error` for
user-triggerable, well-formed-script rejections; `Program_Error` reserved for genuine internal
invariant violations. An out-of-bounds array index or a reference to an undefined array are both
squarely user-script mistakes — the same category ADR-0010/ADR-0012 already cover for scalar/array
redefinition — not internal invariants.

`Set_Array_Element`'s `Program_Error` use predates ADR-0010/ADR-0012 and was never reconciled to
the convention those ADRs established, the same way `Dim_Array`'s virtual/real conflict check
(PC-3, out of scope here) wasn't.

**Call-site verification** (all 8 callers of `Get_Array_Element`, read directly, not assumed):
- `sdata_core-evaluator.adb`: two "whole-array" iteration sites (lines ~339-346, ~50-53 mirrored
  in sdata's `execute_print.adb`) call `Get_Array_Bounds` first and iterate exactly that range —
  a raise from `Get_Array_Element` is unreachable from these sites (the array is known to exist and
  the index is known to be in-range by construction).
- Two "range/list" and "single index" sites in `sdata_core-evaluator.adb` (lines ~384-386,
  ~391-397) resolve a genuinely user-supplied index/range via `Evaluate`. A raise *is* reachable
  here. Both are wrapped in `exception when Constraint_Error => ...` — but that handler exists for
  the *unrelated* numeric-conversion overflow case (`Integer (Real'Floor (...))` etc.), not for
  anything `Get_Array_Element` currently raises (it raises nothing today) — `Script_Error` or
  `Program_Error` both propagate straight past this handler untouched, which is the desired outcome
  either way.
- Two direct `return Get_Array_Element (...)` sites in `Evaluate`/`Eval_Raw` (lines ~552, ~731) —
  the core scalar-expression-context array-access path (e.g. `F(5)` inside `X = F(5) + 1`). No
  local handler at all; a raise propagates straight up through `Evaluate` to the caller.
- Two more "range" and "single index" sites in sdata's `execute_print.adb` (lines ~84-87, ~90-96) —
  same shape as the evaluator's user-supplied-index sites, but with *no* local exception handler at
  all (not even an unrelated `Constraint_Error` one).

No call site swallows, mishandles, or relies on the current silent-missing return as an intentional
signal distinct from "this index happened to be invalid."

**Coder-phase correction (2026-08-21):** the reachability analysis above is correct, but empirical
testing during implementation surfaced a fact this ADR didn't anticipate. In **batch mode**, sdata's
own parser (`sdata-parser.adb`) decides `Expr_Array_Access` vs `Expr_Function_Call` (line ~433) by
checking `Has_Array` against symbol-table state as it stood when that line was parsed — but batch
parsing runs ahead of dispatch, so an array registered by an *immediately preceding* `DIM`/`ARRAY`
statement is not yet visible to that check. Confirmed by instrumentation: `DIM F(1 TO 3)` followed
by `PRINT F(5)` in a `.cmd` file parses `F(5)` as `Expr_Function_Call`, not `Expr_Array_Access`,
even though `F` is already registered. `Expr_Array_Access` is reachable through sdata's own parser
only in REPL/piped-stdin mode (each line parsed and dispatched one at a time). This does not change
the fix's correctness — `Expr_Function_Call`'s own runtime `Has_Array` re-check
(`sdata_core-evaluator.adb:713`) still routes correctly to `Get_Array_Element` whenever the array
*is* currently defined, so the out-of-bounds cases are reachable and verified in plain batch `.cmd`
tests — but the **array-undefined** case (case 1 above) could only be constructed as a real
regression test via a `.repl` test using a virtual array undefined synchronously (`ARRAY V` bare),
not `DROP` (whose column removal is deferred to commit time, `Apply_Pending_Mods`, strictly after
the current RUN's deferred statements already ran). See `sdata/tests/array_element_read_undefined.{cmd,repl,flags}`.

## Decision

1. **`Get_Array_Element`** gains the same three checks `Set_Array_Element` already has (undefined
   array, out-of-bounds index, virtual-array offset overflow), raising `SData_Core.Script_Error`
   with an equivalent message for each — not `Program_Error`.
2. **`Set_Array_Element`'s three existing raises are changed from `Program_Error` to
   `Script_Error`**, closing the same convention gap ADR-0012 already flagged for this function's
   general shape, rather than mirroring the outdated `Program_Error` convention into new code and
   leaving the write path inconsistent with its own new sibling.
3. `Dim_Array`'s unrelated virtual/real conflict check (PC-3) is **not** touched — same scope
   boundary ADR-0012 already drew; a future PC-3 fix reconciles that one.

## Rationale

- One house style for "user referenced something invalid," matching ADR-0010/ADR-0012, rather than
  a second, older style surviving in the one place this workstream touches it anyway.
- Verified, not assumed, that every caller tolerates the change: the "whole-array" sites can never
  reach the new raise; the "user-supplied-index" sites either have no local handler (propagates
  correctly) or a handler for an unrelated exception (also propagates correctly, since it only
  catches `Constraint_Error`).
- `Script_Error` is what the interpreter's top-level dispatch (`sdata-interpreter.adb`'s
  `when E : Script_Error | SData_Core.Script_Error` handler) specifically recognizes as a clean,
  continuable user error; `Program_Error` falls through to the generic `others` handler, which
  produces a reasonable message today but is the wrong semantic signal for a well-formed-script
  rejection.

## Consequences

**Positive**

- Closes PC-1: array-element references are symmetric between read and write, matching design.md
  §2.5/§3.3's unqualified "references... fail" language.
- Removes one instance of the `Program_Error`/`Script_Error` inconsistency ADR-0012 flagged,
  without having to touch `Dim_Array`'s unrelated one to do it.

**Negative**

- Changes `Set_Array_Element`'s already-shipped exception type. Any caller (in any of the three
  repos) that specifically catches `Program_Error` around an array-element write, rather than
  letting it propagate, would need updating — grepped for this before finalizing the design (see
  `01-architect.md`'s Risk Assessment); found none, but this is the one genuine behavior-visible
  change in an otherwise purely-additive fix.

## Alternatives Rejected

- **Mirror `Program_Error` in the new read-path raises, leave `Set_Array_Element` untouched** —
  rejected: cheapest diff, but perpetuates the pre-ADR-0010/0012 convention into code being written
  *after* that convention was established, and leaves read and write using different exception
  types for the identical error condition on the identical data structure.

## Related

- ADR-0010 (`set-let-storage-class-hard-error`), ADR-0012 (`scalar-array-storage-class-hard-error`)
  — the precedent this decision extends to array-element references.
- sdata `.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md` finding
  PC-1.
- sdata `.ssd/features/pc1-array-element-read-error/` — the workstream implementing this decision.
