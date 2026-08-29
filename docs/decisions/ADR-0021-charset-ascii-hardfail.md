---
id: ADR-0021
title: "CSV /CHARSET=ASCII violations hard-fail USE and SAVE instead of warning and continuing"
status: Accepted
date: 2026-08-29
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd8-charset-hardfail/00-brief.md
  - ../../../sdata/.ssd/features/pd8-charset-hardfail/01-architect.md
  - ../../../sdata/.ssd/features/pd8-charset-hardfail/02-systems-designer.md
---

# ADR-0021: `/CHARSET=ASCII` violations fail `USE`/`SAVE` instead of warning and continuing

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-8**, `part-d-file-io-execution-model.md`) found that
design.md states, four separate times across §4.1 and §4.5, that a character-set violation fails
the operation:

- §4.1, CSV Input: *"Invalid characters for detected/specified charset: operation fails with error
  message."*
- §4.1, CSV Output: *"Characters not representable in output charset: operation fails with error
  message."*
- §4.5, Character Set Errors: *"Invalid characters in detected/specified charset (USE): fails with
  error message."*
- §4.5, Character Set Errors: *"Characters not representable in output charset (SAVE): fails with
  error message."*

Neither direction actually failed. `Validate_ASCII` (input, `sdata_core-file_io-csv.adb`) printed
one warning for the first non-ASCII byte on a line and continued; the equivalent inline check
inside `Write_CSV`'s `Write_String` (output) printed one warning for the first non-ASCII byte in a
field, then wrote the field's unconverted bytes anyway. Both were confirmed empirically by the
audit to exit 0 and complete normally.

Both checks are gated exclusively on `/CHARSET=ASCII` (`Needs_ASCII_Chk` on input,
`Eff_Charset = "ASCII"` on output) — UTF-8 (the implicit default) and UTF-16 have separate,
unrelated conversion code paths not touched by this decision.

## Decision

Both `Validate_ASCII` and `Write_String`'s inline ASCII check now `raise SData_Core.Script_Error`
on the first non-ASCII byte encountered, instead of printing a warning and continuing:

- **Input** (`USE .../CHARSET=ASCII`): raises with `"<file>": non-ASCII byte (value <N>) in input
  -- rejected (CHARSET=ASCII)"`. No dataset is loaded.
- **Output** (`SAVE .../CHARSET=ASCII`): raises with `"<file>": non-ASCII byte (value <N>) in
  output -- rejected (CHARSET=ASCII)"`. Rows already flushed to the output stream before the
  failing field remain on disk (see Consequences) — this ADR does not change that.

No `OPTIONS` opt-in flag gates this; the hard-fail is unconditional whenever `/CHARSET=ASCII` is
in effect, matching design.md's four passages literally. This was a direct product decision by the
project owner (recorded in the brief, 2026-08-29), choosing this over an opt-in flag or softening
design.md to match the old warn-and-continue behavior.

Both `raise` sites reuse the existing `Parse_CSV`/`Write_CSV` `when others => Close (File) if
open; raise;` handlers already in the file — no new exception-handling plumbing. `Script_Error` is
caught cleanly at sdata's top level (`sdata_main.adb`'s `when E : SData.Script_Error |
SData_Core.Script_Error | ... => Put_Line_Error ("Error: " & Exception_Message(E))`), the same
path every other documented `USE`/`SAVE` failure (permission-denied, path-too-long, merged cells)
already uses.

**Amendment (code review round 1, MAJOR-1):** the initial implementation missed the CSV header
(column-name) row entirely — `Validate_ASCII` was called from the `Skip_Rows` and `NSCAN`
scan-window loops but never from the header-line read, so a non-ASCII byte confined to the header
row silently succeeded both before and immediately after this ADR's initial landing. Closed by
adding the same `Validate_ASCII` call to the header-read block, immediately after its `Get_Line`
and before BOM-stripping — matching the other two sites' own idiom.

## Rationale

- **Implement the documented hard-fail rather than soften the doc.** Same precedent as PD-6/
  ADR-0019: the audit and the project owner both treat the emphatic, four-times-repeated "fails
  with error message" wording as intended behavior to implement, not aspirational text.
- **No opt-in flag.** Considered (the audit's own report raised it as one option) and explicitly
  rejected by the project owner — every prior PD/PC documented-behavior fix this session shipped
  unconditionally, and an opt-in flag would leave the documented default still wrong.
- **First-offending-byte short-circuit, not exhaustive-per-byte reporting.** Matches the
  pre-existing warning's own granularity; no design.md passage asks for every bad byte to be
  listed.
- **SAVE's partial-output-file behavior is explicitly out of scope, not silently ignored.** No
  existing `Write_CSV` failure path (disk full, permission revoked mid-write) deletes a partial
  output file today; this ADR doesn't change that for the charset case either. design.md's four
  passages promise the *operation* fails — they don't promise the target file is absent or
  untouched afterward. Making every `SAVE` failure mode clean up its partial output is a
  defensible, larger, charset-independent hardening idea with no design.md text behind it —
  tracked as a candidate future finding, not folded into this ADR's scope.

## Consequences

**Easier:** a `USE`/`SAVE` under `/CHARSET=ASCII` now behaves exactly as documented — a script
relying on the guarantee that "invalid characters fail the operation" gets that guarantee for real,
instead of silently loading or writing data it explicitly asked to reject.

**Harder:** any existing script that (knowingly or not) relied on the old warn-and-continue
behavior to load or save data containing non-ASCII bytes under `/CHARSET=ASCII` will now fail and
needs updating — this is the intended, documented behavior, not a regression. (Zero existing sdata
or data-vandal tests exercised `/CHARSET=ASCII` at all before this change, confirmed by grep during
systems-design review — so no test suite needed rework, but a real-world script might.)

**Gives up:** the previous behavior of a "best-effort" `SAVE` that writes non-ASCII bytes anyway
with only a warning. A user who wants that leniency must not specify `/CHARSET=ASCII` (the default
charset detection/UTF-8 path is unaffected by this decision).

**A UTF-8 BOM in the header row now hard-fails under `/CHARSET=ASCII`.** Since the header-line
check (added by the round-1 amendment above) runs before the existing BOM-stripping logic, a file
with an otherwise-100%-ASCII body but a leading UTF-8 BOM (a common artifact of Excel/Windows CSV
exporters) is rejected rather than silently accepted with the BOM stripped. This is intentional,
not a bug (design.md documents no BOM-stripping guarantee for any charset, let alone an ASCII
one, and a BOM's bytes are definitionally non-ASCII) — noted here, with a pinning regression test
(`charset_ascii_bom_header_reject.cmd`), so a future change doesn't silently "fix" this by moving
the check after BOM-stripping under the mistaken assumption it's a regression.

## Alternatives Rejected

- **Opt-in via a new `OPTIONS` flag (e.g. `CHARSET_STRICT`), default off.** Rejected by explicit
  project-owner decision: every prior documented-behavior gap this session closed (PD-5/PD-6/PD-7)
  shipped unconditionally, and design.md's wording doesn't describe an opt-in.
- **Soften design.md's four passages to describe the warn-and-continue behavior instead.**
  Rejected: the audit itself leaned toward implementing the documented behavior given how
  emphatically and repeatedly it's stated, and the project owner's decision confirms this.
- **Deleting the partial output file on a SAVE charset failure.** Considered during design
  (architect design question 3) and deliberately left out of scope — no design.md text requires
  it, and it's a behavior shared by every `Write_CSV` failure mode, not specific to charset
  violations.
