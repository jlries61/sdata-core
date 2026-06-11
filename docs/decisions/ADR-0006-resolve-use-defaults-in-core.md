---
id: ADR-0006
title: "USE-default resolution centralized in core via Resolve_Use_Defaults"
status: Accepted
date: 2026-06-11
related:
  - src/sdata_core-commands.ads
  - src/sdata_core-commands.adb
  - ADR-0004
  - ADR-0005
---

# ADR-0006: USE-default resolution centralized in core via Resolve_Use_Defaults

## Status

Accepted.

## Context

The USE command loads a dataset. Three of its options — the field
delimiter, the read-header flag, and the charset — may be specified on
the USE statement itself, or omitted, in which case they fall back to
the corresponding `OPTIONS` runtime setting
(`SData_Core.Config.Runtime.Options_CSVDLM` / `Options_Header` /
`Options_CHARSET`).

`Execute_USE` did not perform that merge. It took already-resolved
`Delimiter` / `Read_Header` / `Charset` parameters (with the literal
hard defaults `","` / `True` / `""`) and forwarded them straight to the
file reader. Resolving "specified on the statement, else fall back to
OPTIONS" was left to each consumer — and the two consumers did it
differently:

- **sdata** open-coded the merge as three conditional expressions, in
  two places (single-dataset USE and the multi-dataset USE loop), reading
  `Options_CSVDLM` / `Options_Header` / `Options_CHARSET` itself.
- **data-vandal** did no merge: it passed only path / format / charset
  and relied on `Execute_USE`'s hard parameter defaults, so it could not
  honor OPTIONS state for delimiter or header at all.

This is the skeptic audit's Evans **E1** finding ("default delimiter /
USE defaults has two authorities"). It is the one open finding that is a
genuine cross-consumer coherence gap rather than localized polish: the
two consumers can disagree on "what delimiter does USE use when none is
given," and the rule lives nowhere canonical. It is also the only open
item that cannot be fixed inside sdata-core's walls alone — closing it
requires both consumers to move in concert, so it would not happen
opportunistically.

## Decision

Add a single resolver to `SData_Core.Commands` — the package that already
owns command semantics and already reads `Config.Runtime` state — and
route every consumer USE call site through it:

```ada
type Use_Defaults is record
   Delimiter     : String (1 .. Max_Delimiter_Len) := (others => ' ');
   Delimiter_Len : Natural := 0;
   Read_Header   : Boolean := True;
   Charset       : String (1 .. Max_Charset_Len)   := (others => ' ');
   Charset_Len   : Natural := 0;
end record;

function Resolve_Use_Defaults
  (Delimiter           : String  := "";
   Delimiter_Specified : Boolean := False;
   Read_Header         : Boolean := True;
   Header_Specified    : Boolean := False;
   Charset             : String  := "";
   Charset_Specified   : Boolean := False) return Use_Defaults;
```

When a `*_Specified` flag is `False`, the corresponding `Options_*`
accessor supplies the value; when `True`, the caller's value is used
verbatim. The function returns a bounded record (fixed `String` + length)
so there is no unconstrained return and the value copies cleanly.

Design points that fell out of the implementation:

- **Specified flags, not emptiness, signal "given."** An empty `Charset`
  is a *legal explicit value* ("autodetect"), distinct from "charset
  unspecified," so the caller must pass an explicit `Charset_Specified`
  rather than letting the function infer it from `Length = 0`. (In
  practice neither consumer's grammar can express an explicit empty
  charset today, so each derives the flag from a length test — but the
  API does not bake that limitation in.)
- **The delimiter is decoded by the consumer.** Consumers map surface
  forms like `TAB` / `PIPE` to the literal character before calling;
  the OPTIONS fallback is used verbatim.
- **A standalone function, not folded into `Execute_USE`.** Keeping the
  resolver separate leaves the headline `Execute_USE` signature — the
  most-depended-on entry in the public stability contract — untouched.
  The change is purely additive.
- **Format resolution stays consumer-side and out of scope.** USE's
  format falls back to `SData_Core.Config.Input_Format` (not an OPTIONS
  field), `Format_Type` has no "unspecified" sentinel, and both
  consumers already resolve it consistently. Bundling it would add risk
  for no coherence benefit.

## Consequences

**Positive**

- The merge rule for delimiter / header / charset now has one canonical
  home. A future third consumer cannot accidentally re-encode it
  differently; it calls `Resolve_Use_Defaults` like the others.
- Closes Evans E1. data-vandal is now wired through the same authority,
  so if it ever gains an OPTIONS command it honors it for free.
- Purely additive to the public API — `Execute_USE`'s signature is
  unchanged, so no existing caller breaks.

**Negative**

- The resolver is *opt-in*: a consumer can still call `Execute_USE`
  directly and bypass the merge. Folding the merge into `Execute_USE`
  (via `*_Specified` flag parameters) would have made bypass structurally
  impossible, at the cost of churning the headline signature. We chose
  signature stability over enforcement, given only two known consumers.

**Neutral**

- No observable behavior change in either consumer today: sdata's merge
  is preserved exactly, and data-vandal — which has no OPTIONS command —
  resolves to the same hard defaults (`,` / `True` / autodetect) it used
  before. The value is coherence and future-proofing, not a bug fix to
  current output.
- Versioned as an additive minor bump (`0.1.9` → `0.1.10`); both
  consumers bump their `^0.1.10` constraint in the same change set per
  the stability contract.

## Related

- ADR-0004 — established `Commands` as the home for command semantics and
  the sole write surface for `Config.Runtime`; this resolver lives there
  for the same reason.
- ADR-0005 — centralized OPTIONS *write* validation in core while leaving
  the value vocabulary consumer-side; its "Related" note explicitly
  carved out E1 (this decision) as the separate concern.
