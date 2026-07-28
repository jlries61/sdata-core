---
id: ADR-0010
title: "SET/LET storage-class redefinition is a hard error, not an implicit conversion"
status: Accepted
date: 2026-07-25
related:
  - ../../sdata/doc/specs/2026-07-24-set-let-storage-class-hard-error-design.md
  - ../../sdata/doc/adrs.md
---

# ADR-0010: SET/LET storage-class redefinition is a hard error, not an implicit conversion

## Status

Accepted.

## Context

`SData_Core.Variables.Set_Temporary` (the `SET` handler) and `Set_Permanent`
(the `LET` handler) previously let the assignment verb silently decide, and
change, a variable's storage class: `SET` on an existing permanent (table)
column demoted it to a temporary variable (dropping the column, with only a
stderr warning); `LET` on an existing genuine temporary variable silently
promoted it to permanent. Both consumers (`sdata`, `data-vandal`) inherit
this behavior directly, since both call these procedures without
modification.

The demotion direction was a genuine data-integrity footgun (sdata issue
[#56](https://github.com/jlries61/sdata/issues/56), same family as sdata
issues #50-#52): a `SET` where `LET` was intended silently dropped a column
from the output with exit code 0. It was also the root cause of a real data
corruption bug: `Set_Temporary`'s call to `Table.Drop_Column` shifted every
later column's position without updating the parallel PDV structures, which
assume positional correspondence with table columns -- corrupting every
column after the demoted one for the rest of the RUN, and reappearing as
stale/malformed `SAVE` output.

Full design rationale, rejected alternatives, and the exact mechanism are in
sdata's `doc/specs/2026-07-24-set-let-storage-class-hard-error-design.md`.

## Decision

Both `Set_Temporary` and `Set_Permanent` raise `SData_Core.Script_Error`
when asked to redefine a name across storage classes, instead of silently
converting it. No new syntax or modifier is introduced. The existing
`Is_Held` guard in `Set_Permanent` is preserved unchanged, so `LET` on a
held-permanent variable (whose value is mirrored into `Temp_Symbols` by
`Reset_PDV_Non_Held` to survive across records) continues to succeed --
that is an ordinary update, not a promotion.

Explicit, deliberate conversion remains possible via existing primitives,
unchanged by this decision: `DROP x` (effective after the next `RUN`) then
`SET x = ...` to convert a column to a temp var; `UNSET x` then
`LET x = ...` to convert a temp var to a column.

## Consequences

**Positive**

- Closes the silent data-loss and PDV/table corruption described above.
- Brings scalar assignment in line with the array-assignment precedent
  already enforced in sdata's `Execute_Array_Assignment`, which already
  raises `Script_Error` for the equivalent wrong-direction cases on array
  elements.
- No API signature change; both consumers pick up the new behavior via the
  version bump with no call-site changes required.

**Negative**

- A script that relied on the old implicit conversion (in either direction)
  now errors instead of silently succeeding. A repository-wide search found
  no test, doc passage, or example script anywhere in sdata, sdata-core, or
  data-vandal that relied on this behavior as an intentional feature -- the
  one sdata test that exercised it (`variable_scoping.cmd` "Test 3:
  Promotion") treated it as the thing under test, not a dependency of some
  other feature, and is rewritten to assert the new error instead.

## Related

- sdata issue [#56](https://github.com/jlries61/sdata/issues/56)
- sdata `doc/specs/2026-07-24-set-let-storage-class-hard-error-design.md`
- sdata issues #50-#52 (the same "silent corruption -> loud error" family)
