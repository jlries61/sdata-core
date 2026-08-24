---
id: ADR-0017
title: "OOXML relationship Target resolution branches on absolute vs. relative form; '../'-relative normalization deliberately out of scope"
status: Accepted
date: 2026-08-24
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd3-ooxml-absolute-target-path/00-brief.md
  - ../../../sdata/.ssd/features/pd3-ooxml-absolute-target-path/01-architect.md
---

# ADR-0017: OOXML relationship `Target` resolution branches on absolute vs. relative form

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-3**, `part-d-file-io-execution-model.md`) found that
`Find_Sheet_XML_Path` in `sdata_core-file_io-ooxml.adb` unconditionally resolves a worksheet
relationship's `Target` attribute as `"xl/" & Target`, correct only for the OPC-relative `Target`
form (the only form LibreOffice writes, and the only form any existing `tests/data/*.xlsx` fixture
exercises). Per ECMA-376 Part 2 (Open Packaging Conventions), `Target` may also be **absolute**
(leading `/`, meaning "already a complete package-root path") — a form openpyxl, one of the most
widely used Python `.xlsx`-writing libraries, actually emits for the worksheet relationship.
Re-verified empirically this session with a real openpyxl 3.1.5-generated file: the blind prepend
produces a doubled zip-entry path (`xl//xl/worksheets/sheet1.xml`), and `Parse_OOXML` rejects the
file outright, even though it is spec-compliant and openpyxl-generated `.xlsx` files are a
significant, real-world class of input, not a synthetic edge case.

## Decision

`Find_Sheet_XML_Path`'s `Target`-resolution branch now checks for a leading `/`:

- **Absolute** (`Target (Target'First) = '/'`): strip the leading `/`, use the remainder as-is as
  the zip-entry path — it is already a complete package-root path per spec.
- **Relative** (no leading `/`): unchanged existing behavior, `"xl/" & Target`.

These are the only two forms OPC's `Target` attribute defines, so this is a complete case analysis.

**Explicitly out of scope**: normalizing `../` segments that could in principle appear in a
*relative* `Target` (e.g., `../customXml/item1.xml`, a valid OPC relative-reference escaping one
folder level up). This is a theoretically adjacent gap in the branch this fix leaves untouched — but
it is not what PD-3 reports, reproduces, or is scoped to fix, and no fixture, the openpyxl repro, nor
any known `.xlsx` writer in this project's experience has ever emitted a `../`-relative worksheet
`Target`. There is zero evidence this case is reachable in practice, unlike the absolute-`Target`
case, which is empirically confirmed reachable via a mainstream library's default output.

## Rationale

Fixing an unreproduced, unreported case while touching adjacent code would add real complexity
(proper relative-path segment resolution, not a simple leading-character check) with no concrete
input driving it — the kind of scope creep this project's "design for the next 10x, not 100x" /
no-premature-abstraction norms argue against. If a real `../`-Target `.xlsx` file surfaces later, it
warrants its own evidence-driven bug report, meeting the same bar PD-3 itself met (a real generated
file, not a hypothetical).

## Consequences

**Easier**: openpyxl-generated `.xlsx` files (and any other spec-compliant writer using the absolute
`Target` form) now load correctly, matching design.md §4.1's "same behavior as ODF" multi-sheet
promise, which the bug violated by rejecting such files outright.

**Unchanged**: the relative-`Target` code path (`"xl/" & Target`) is byte-for-byte identical to
before — every existing `.xlsx` fixture, all of which use the relative form, is unaffected.

**Harder / accepted gap**: the relative-`Target`-with-`../` case remains unaddressed. Documented
inline as a known, deliberately out-of-scope gap (one-line code comment) so a future reader doesn't
mistake this fix for a complete `Target`-resolution rewrite.

## Alternatives Rejected

**Full OPC-compliant relative-URI resolution** (generic handling of `../`, `./`, and multi-segment
relative paths for *both* branches) — rejected; would be justified only by a real repro, which does
not exist for the relative-`../` case today. Matching PD-3's own scope exactly, and this project's
established practice of not fixing unreproduced hypotheticals while touching nearby code (see, e.g.,
ADR-0015's/ADR-0016's own scoping decisions).
