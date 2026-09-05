---
id: ADR-0025
title: "USE/reshape-time column load auto-undefines a colliding pre-existing array registration, instead of silently shadowing it"
status: Accepted
date: 2026-09-05
related:
  - ADR-0010-set-let-storage-class-hard-error.md
  - ADR-0012-scalar-array-storage-class-hard-error.md
  - ADR-0015-array-kind-replacement-symmetric-rules.md
  - ADR-0024-use-time-array-detection-skips-scalar-collision.md
  - jlries61/sdata-core#132
---

# ADR-0025: USE/reshape-time column load auto-undefines a colliding pre-existing array registration, instead of silently shadowing it

## Status

Accepted.

## Context

GitHub issue [jlries61/sdata-core#132](https://github.com/jlries61/sdata-core/issues/132),
found while code-reviewing ADR-0024's fix for #117: if a name is already registered as an array
(via `ARRAY` or `DIM`), and a later `USE` — or an `AGGREGATE`/`TRANSPOSE`/`STATS` reshape, which
replaces the in-memory table the same way `USE` does — loads a table whose columns include a
literal column with that exact name, the freshly-loaded column's real data is silently shadowed:
`PRINT` on that name resolves through the stale array registration (often now-missing, since the
old table backing its constituents was just overwritten), not the newly-loaded column's actual
value.

This is the same defect *shape* ADR-0010 and ADR-0012 both closed — a name silently meaning two
incompatible things at once, with ordinary reference syntax resolving to the wrong one — on a
**fourth path** neither of those ADRs reaches: `SData_Core.Table.Add_Column`, the bulk column-load
primitive both `USE` and the reshape commands funnel through. `Table` has no dependency on
`SData_Core.Variables`/`Array_Symbols` — architecturally, `Table` sits *below* `Variables` in this
crate's dependency graph — so `Add_Column` cannot consult `Array_Symbols` before creating a column
without a layering change. Every existing scalar/array collision guard (`Set_Temporary`,
`Set_Permanent`, `Dim_Array`, and `Register_Subscripted_Columns` per ADR-0024) lives in `Variables`
and is reachable only through `Variables`' own entry points; none of them sit on this path.

Confirmed independent of #117/ADR-0024 by isolated reproduction: no `base(n)`-shaped column or
`Register_Subscripted_Columns` involvement is needed — a single plain, non-subscripted colliding
column name is sufficient.

## Decision

A new post-load reconciliation pass, `SData_Core.Variables.Resolve_Column_Array_Collisions`,
scans every column in the just-loaded table (`Table.Column_Count`/`Table.Column_Name`, the same
enumeration `Register_Subscripted_Columns` already uses) and, for each column name that is also a
registered array (`Has_Array`), **undefines that array registration** (`Undefine_Array` — both
virtual and real kinds, not just virtual) and prints a notice:

> `USE: array "<NAME>" was already defined (unrelated to the just-loaded dataset); removing its registration -- column "<NAME>" from the loaded dataset takes precedence.`

This runs at both of `Register_Subscripted_Columns`'s existing call sites — `Execute_USE` and the
`Commit_Reshaped_Table` reshape epilogue (`sdata_core-commands.adb`) — immediately **before**
`Register_Subscripted_Columns`, so that routine's own ADR-0024 messaging (which itself checks
`Has_Array`) reflects the post-reconciliation state rather than reporting a registration this pass
is about to remove anyway.

Because `USE` and the reshape commands both **replace the entire in-memory table** ("the internal
table shall be overwritten with the contents of the file" — design.md), "every column in the
just-loaded table" and "every column this operation just loaded" are the same set at the point this
pass runs; no column present before this operation can survive to be mistaken for one it just
loaded.

## Rationale

- **Extends ADR-0015's precedent, not a new philosophy.** ADR-0015 already established that `DIM`
  silently replaces an existing virtual array rather than raising, accompanied by a notice — this
  ADR applies the identical "replace, don't raise, but say so" resolution to the one remaining path
  (bulk column load) that reaches the same kind of collision. `Undefine_Array` (not
  `Undefine_Virtual_Array`) is used so the resolution is symmetric across both array kinds, matching
  how ADR-0024's sibling fix also checks `Has_Array`/`Kind` without special-casing virtual vs. real.
- **Rejects "raise" (parity with `Set_Temporary`/`Set_Permanent`/`Dim_Array`'s ADR-0010/ADR-0012
  hard-error philosophy).** Those hard errors guard *explicit, user-typed* redefinition of a
  specific name (`LET Q = ...`, `DIM Q(...)`) — the user's intent is unambiguously about `Q`.
  `USE`'s column-name collision is *incidental*: the user's intent is "load this file," and `Q`
  merely happens to also be the name of what is very likely stale, forgotten array state from
  earlier in the session. Aborting the entire load over an incidental collision with probably-stale
  state is the same disproportionate failure mode ADR-0024 already rejected for the sibling
  `base(n)` case — the user needs their data loaded far more than they need a leftover array
  registration preserved. `USE`'s own overwrite semantics already unconditionally discards every
  prior table column; extending that same "the explicit load wins" posture to a conflicting
  `Array_Symbols` entry is consistent with what `USE` already does to everything else in scope, not
  a new category of surprise.
- **Rejects "warn but leave the array registration in place."** Unlike ADR-0024's case — where
  *not* creating a new array registration fully resolves the ambiguity (nothing to leave unchanged,
  because nothing new is being introduced to be tracked) — here an existing registration actively
  intercepts every reference to the name. Warning without removing it would not fix the user-visible
  bug at all: `PRINT Q` would still resolve through the stale array, exactly as broken as today. A
  fix that only prints a message without changing what `Q` resolves to isn't a fix.

## Consequences

**Positive**

- Closes #132: a freshly-loaded column can no longer be silently shadowed by an unrelated,
  pre-existing array registration of the same name — the load succeeds, the notice explains what
  was removed and why, and the column's real data is what `PRINT`/ordinary reference syntax
  actually returns afterward.
- Consistent house style: this is the third instance of "the codebase's automatic/bulk operations
  resolve a stale-registration collision by replacing and notifying, not by raising" (ADR-0015 for
  `DIM`, ADR-0024 for `Register_Subscripted_Columns`, now this for bulk column load) rather than a
  fourth, different convention.
- No public API signature change to any existing procedure; one new public procedure added to
  `SData_Core.Variables`.

**Negative**

- A user who *relies* on an array registration surviving across an unrelated `USE` (there is no
  known legitimate use case for this — an array's constituents are themselves either temp vars or
  table columns, both of which `USE`'s own table-overwrite already invalidates today) loses that
  registration silently unless they read the notice. This mirrors ADR-0015's own accepted trade-off
  for `DIM`.
- Iterates every column in the freshly-loaded table once more (`Has_Array` per column), in addition
  to `Register_Subscripted_Columns`'s own per-column pass — negligible cost; both passes already run
  once per `USE`/reshape, not per row.

## Alternatives Rejected

See "Rationale" above for the rejected "raise" and "warn without removing" alternatives. A third
alternative — teaching `Table.Add_Column` to consult `Array_Symbols` directly — was rejected because
it requires `Table` to depend on `Variables`, inverting this crate's established package layering
(`Variables` depends on `Table`, not the reverse) for one narrow check; a post-load reconciliation
pass in `Variables` (which already depends on `Table` and already runs exactly this kind of pass for
`Register_Subscripted_Columns`) achieves the same result without the layering change.

## Related

- ADR-0010 (`set-let-storage-class-hard-error`), ADR-0012
  (`scalar-array-storage-class-hard-error`) — the storage-class hard-error precedent this ADR
  extends to a fourth path, but resolves differently (replace, not raise) because the collision is
  incidental rather than user-typed.
- ADR-0015 (`array-kind-replacement-symmetric-rules`) — the "replace, don't raise, but notify"
  precedent this decision applies here.
- ADR-0024 (`use-time-array-detection-skips-scalar-collision`) — the sibling fix (#117) this issue
  was found reviewing; shares both call sites and the "incidental collision, don't abort the load"
  reasoning.
- `jlries61/sdata-core#132` — the issue this decision resolves.
