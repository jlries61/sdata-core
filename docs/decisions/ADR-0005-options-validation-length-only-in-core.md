---
id: ADR-0005
title: "OPTIONS validation: length in core, semantics in consumers"
status: Accepted
date: 2026-05-26
related:
  - src/sdata_core-commands.adb
  - https://github.com/jlries61/sdata-core/pull/5
  - https://github.com/jlries61/sdata/pull/8
---

# ADR-0005: OPTIONS validation: length in core, semantics in consumers

## Status

Accepted.

## Context

When sdata-core PR #5 added the `Execute_OPTIONS_*` family (see
ADR-0004), each of the three `String`-valued procedures (`CSVDLM`,
`TXTFMT`, `CHARSET`) faced a validation question. Three `String` inputs
are stored in fixed-length backing fields:

- `Options_CSVDLM` is `String (1 .. Max_Delimiter_Len)` (cap of 8)
- `Options_TXTFMT` is `String (1 .. Max_Delimiter_Len)` (cap of 8)
- `Options_CHARSET` is `String (1 .. Max_Charset_Len)` (cap of 64)

The pre-migration sdata-side handlers truncated silently:
`VL := Natural'Min (Val_Upper'Length, 8)` and then sliced the input to
fit. A user typing `OPTIONS TXTFMT VERYLONGNAME` would silently get
`VERYLONG`, with no signal that the value was clipped.

Two layers of validation were possible:

1. **Length validation** — reject inputs longer than the storage cap.
   Mechanical, type-safe, easy to specify, and gives a clear error.
2. **Semantic validation** — reject inputs that are not in the
   recognised value set (e.g., `OPTIONS TXTFMT FOO` should fail because
   only `AUTO`, `CSV`, `FIXED`, etc. are recognised).

Adopting either, both, or neither was a real design choice.

Audit Evans E2 flagged the missing length check specifically: the
audit's reading was that the absence of validation made `Config.Runtime`
"just a persistence schema with methods" — Evans's classic anemic
critique. The audit's recommendation was to add validation in the new
procedures.

## Decision

The `Execute_OPTIONS_*` procedures perform **length validation only**:

- `Execute_OPTIONS_CSVDLM (Value : String)` — rejects empty strings
  (a zero-length delimiter is nonsense) and `Value'Length > 8` with
  `SData_Core.Script_Error`.
- `Execute_OPTIONS_TXTFMT (Value : String)` — rejects empty strings
  and `Value'Length > 8`.
- `Execute_OPTIONS_CHARSET (Value : String)` — allows empty (existing
  "autodetect" convention) and rejects `Value'Length > 64`.

Semantic validation (the recognised-value set for `TXTFMT`,
the encoding-name set for `CHARSET`, etc.) is **out of scope** for core.
The recognised set lives in each host application's grammar; encoding
it in core would either fork the source of truth or require core to
import an interpretation layer that doesn't belong here.

This is a deliberate behaviour change from the pre-migration silent
truncation. The first migration commit (sdata PR #8) acknowledges
this explicitly: an over-long OPTIONS input that previously got
clipped now raises `Script_Error` with a descriptive message. sdata's
full test suite passes unchanged through the migration, indicating no
existing test exercised the truncation path — the change is a strict
improvement for any user who actually typed a too-long value.

## Consequences

**Positive**

- A too-long OPTIONS input fails loudly with a useful message instead
  of silently producing a truncated state.
- The validation is mechanical (a single `'Length` check), type-safe,
  and lives in a small number of procedures.
- The `Script_Error` exception is already part of the public API and
  is caught by sdata's existing error handler — the new failure mode
  composes correctly with the existing error-recovery path.

**Negative**

- Semantic validation gaps remain. `OPTIONS TXTFMT GARBAGE` (8 chars,
  not a recognised value) will pass length validation, succeed at the
  field write, and then fail later when the host application tries to
  interpret it. This is the existing behaviour; the ADR does not change
  it.
- A separate Evans bounded-context smell is flagged but unresolved:
  the OPTIONS-value vocabulary lives in two crates. A future ADR may
  revisit this with either a callback hook for semantic validation or
  a host-supplied recognised-value set.

**Neutral**

- The audit's Evans finding is not fully closed by this ADR; it is
  partially closed for length and explicitly deferred for semantics.
  This nuance is recorded so a re-audit does not claim full closure.

## Related

- ADR-0004 — drove the existence of the `Execute_OPTIONS_*` family in
  the first place.
- The skeptic-before.md Evans section (E1, E2) identified the validation
  gap. E1 (the "two USE-default-resolution paths" problem) is a
  separate but related concern.
