---
id: ADR-0027
title: "Declared column types (USE /TYPES=): one shared applier, a lock in every reader, and warning parity across formats"
status: Accepted
date: 2026-09-25
related:
  - ADR-0019-scan-window-any-nonnumeric-forces-character.md
  - ADR-0020-coercion-warning-cap.md
  - ADR-0026-missing-value-tokens.md
  - ../../../sdata/doc/adrs.md (sdata ADR-084 -- the language-surface decision this implements)
  - ../../../sdata/.ssd/features/column-type-override/01-architect.md
  - ../../../sdata/.ssd/features/column-type-override/02-systems-designer.md
---

# ADR-0027: Declared column types for all three readers

## Status

Accepted.

## Context

sdata's `USE` gained `/TYPES=`, a per-column type declaration that opts named columns out of type
inference (sdata ADR-084). It exists because `NSCAN` is a speed-for-accuracy trade whose failure mode
previously had no cheap recovery: a wrong guess cost a full re-read of the file, corrected globally
(scan more rows for *every* column) for what is usually a local problem (one column).

This crate owns all three readers and therefore owns what "declared type" actually means per format.

The design's initial premise was that this would be nearly free, because all three readers already
derive a column's type from its name's `$`/`%` suffix — ODF and OOXML through the shared
`Apply_Name_Suffix_Types`, CSV through an inline equivalent. Reading that helper showed the premise
was wrong in the case that matters most:

```ada
if    Raw (Raw'Last) = '$' then Col_Types (I) := Col_String;
elsif Raw (Raw'Last) = '%' then Col_Types (I) := Col_Integer;
end if;
```

A suffix can only *set* `Col_String` or `Col_Integer`. **"No suffix" does not mean float; it means
unspecified — still subject to inference.** So a name rewrite cannot express *force float*, which is
precisely the cliff case. And the ability to lock a column against inference was asymmetric: CSV had
`Col_Determined`, while ODF and OOXML guarded their row-1 inference only with
`Col_Types (Col_Idx) /= Col_Integer` and had no lock at all.

## Decision

**One shared parser and one shared applier.** `File_IO.Helpers` gains `Parse_Declared_Types`
(canonical `"NAME,NAME$,NAME%"` → table; errors on an empty entry or a repeated base name) and
`Apply_Declared_Types` (sets `Col_Types`, marks `Col_Locked`, emits the header-conflict note, and
hard-errors on a declared column the file lacks). All three readers call the same two. Three readers
each hand-rolling this would rebuild, at triple width, the divergence ADR-0026 was created to stop.

**One shared naming rule.** `Final_Column_Name (Base_Name, Col_Typ)` returns the name whose suffix its
type implies. This is behavior-identical to the append-`$`-if-string expression each reader open-coded
(a `$`-header is `Col_String` and keeps its `$`; a `%`-header is `Col_Integer` and keeps its `%`), but
it also handles the case only `/TYPES=` can create: a **demoted** column, where the header says `CODE$`
and the declaration says float, whose name must lose the suffix rather than leave a numeric column
called `CODE$`. Verified behavior-preserving by the full suite passing unchanged.

**A lock array in ODF and OOXML.** Both gain `Col_Locked`, consulted by their row-1 inference. Without
it a declared-float column would be silently re-inferred to character and the declaration would appear
to do nothing. CSV needed no new concept — `Col_Determined` is the same lock, now fed from a second
source. Verified sufficient by enumeration: `Col_Types` is mutated in exactly three places per reader
(initialisation, `Apply_Name_Suffix_Types`, row-1 inference) and nothing retypes during row loading.

**`Get_Cell_Value` honors `Target_Type` on its string-producing paths, opt-in.** This is the half the
lock does not cover. Before it, a declared-float spreadsheet column receiving text cells produced
`Col_Numeric` holding `Val_String`, which `Coerce_Value` answers with `Type_Mismatch_Error`, caught by
a generic per-cell handler and reported in unrelated words — not the documented coerce-to-missing. Now
a string cell bound for a numeric column is parsed as a number, falling back to `Val_Missing`, mirroring
the numeric branch's own long-standing `Real'Value` + `Constraint_Error` shape. OOXML has **three**
string-producing paths (shared string, `str`, inline `is`), so the logic lives in one local `As_Typed`
function rather than being written three times.

Coercion is **opt-in** (`Coerce_To_Target`, default `False`), and only the data-loading call sites opt
in. This was not the first attempt: making it unconditional regressed the ODF basic-load tests, because
the schema-inference probe calls `Get_Cell_Value` purely to ask what a cell *naturally* is, and OOXML's
header collector does too. Both relied on the pre-existing behavior that a string cell stays a string;
coercing for them made text columns come out numeric and header names vanish. Defaulting to `False`
keeps every non-loading caller on exactly its previous behavior.

**Warning parity (ADR-0020 extended to the spreadsheet readers).** Their coercion warnings now route
through the same counter, the same cap of ten, the same suppression summary, and the **same message
wording** as CSV's. Previously the spreadsheet path warned once per cell, uncapped — so a declared
numeric column over a 50,000-row text column would have emitted 50,000 warnings. This is what makes
sdata ADR-084's "one rule for every format" claim true rather than aspirational; the two messages were
compared by running both readers and diffing the output.

## Consequences

**Easier**: a wrong type guess is now recoverable without re-reading the file or editing it, on all
three input formats, with identical user-visible behavior and identical diagnostics.

**Harder / disclosed**: `Get_Cell_Value` now has a mode flag, and a future caller that wants coercion
must remember to pass it. The default is the safe direction (no coercion, previous behavior), so a
forgotten flag under-coerces rather than corrupting a column — but it is a flag, and flags get missed.
The three-place `Col_Types` enumeration that justifies the single lock site is a *current* fact, not an
invariant the compiler enforces; a fourth mutation added later would need its own guard.

**Unchanged**: ADR-0019's scan-window inference rule. This is additive to it — it governs columns the
user did *not* declare, which is still most of them.

## Alternatives Rejected

**Implement the override as a header-name rewrite, reusing `Apply_Name_Suffix_Types` untouched** —
rejected: cannot express force-float, the primary case (see Context).

**Add the lock only, and accept the spreadsheet behavior that follows** — rejected: it fixes the
column's type while leaving its values raising `Type_Mismatch_Error`, which would have shipped as a
feature that looks complete and silently mangles data. Notably, a test asserting only the resulting
column *type* passes in that state, which is why the acceptance tests assert stored values.

**Give the spreadsheet readers their own warning cap and wording** — rejected in favor of reusing
ADR-0020's, so design.md describes one rule instead of a CSV rule plus a carve-out.

**Extend `RENAME=` to cross the numeric/character boundary instead** — rejected: ADR-044 defers value
conversion, and `RENAME=` runs post-load, so it cannot influence how values are parsed in the first
place. Different mechanism, different phase.
