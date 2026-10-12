---
id: ADR-0030
title: "Extract Parse_Expression into its own subunit"
status: Accepted
date: 2026-10-12
related:
  - sdata/doc/SOFTWARE_STANDARDS_REVIEW.md (SSR-2-PARSE-EXPRESSION)
  - ../../.ssd/features/extract-parse-expression/refactor-plan.md
---

# ADR-0030: Extract `Parse_Expression` into its own subunit

## Status

Accepted.

## Context

`sdata/doc/SOFTWARE_STANDARDS_REVIEW.md` §2 flagged `Parse_Expression`
(`sdata_core-evaluator.adb:777-1272`, 495 lines) as an oversized-procedure outlier — the third and
final target from that finding, after `Stmt_USE` (sdata's
`sdata-interpreter-execute_declarative.adb`) and `SData_Main`'s three nested routines plus its
CLI argument-parsing loop, both already extracted in sdata.

`Parse_Expression` is already internally decomposed into a self-contained recursive-descent
mini-parser — `Advance` (the lexer), `Expect`, `Get_Prec`, `To_Bin_Op`, `Parse_Expr_1`
(precedence-climbing), `Parse_Primary`, `Parse_Or` — nested inside one function rather than living
in its own subunit the way `Execute_Tables` (sdata) already does for one complex command, and the
way the two prior extractions in this series now do.

## Decision

Move the entire function body (unchanged — all nested helpers stay nested inside it, exactly as
they were) into a new subunit, `src/sdata_core-evaluator-parse_expression.adb`, with
`sdata_core-evaluator.adb` reduced to `function Parse_Expression (Text : String) return
Expression_Access is separate;` in the same position.

## Rationale

`Parse_Expression (Text : String)` is named explicitly in this crate's `CLAUDE.md` as part of the
public contract both `sdata` and `data-vandal` call directly — it is how each consumer's own
parser hands `SELECT`/dataset-option `IF=` expression text back to the shared evaluator without
sharing AST types (per `sdata` ADR-040). This refactor does not touch that contract: the
declaration in `sdata_core-evaluator.ads` (line 194) is unchanged; only the body's *location*
moves, from directly in the package body to a subunit of it. This is invisible to any caller, the
same way moving `Stmt_USE`'s body into its own subunit was invisible to `sdata-interpreter.ads`'s
callers.

Confirmed via exhaustive grep (not sampling) that `Parse_Expression`'s body has zero dependency on
anything declared in `sdata_core-evaluator.adb`'s package-body scope before it — the two hits for
other body-level function names (`Evaluate_Function`, `Get_Expected_Kind`, `Evaluate`) are both
inside comments, not code. Everything it actually uses (`Binary_Op`/`Op_Add` etc., `Max_Name_Len`,
`Is_Letter`/`To_Upper`/etc., `Pos_Inf`/`NaN_Val`) comes from the package spec or `with`-ed
packages, already globally visible regardless of subunit stub position — so unlike the `Stmt_USE`
extraction (which needed `Dlm_To_Str` promoted into the parent body for two sibling arms to keep
sharing it), this one needed no shared-helper promotion at all.

## Consequences

- **Easier:** `sdata_core-evaluator.adb` shrinks by ~495 lines; `Parse_Expression` lives in its
  own appropriately-named file, matching the pattern this crate and `sdata` both now use for
  every other oversized-but-already-decomposed procedure.
- **Harder:** nothing. No behavior changed, no interface changed, no new invariant introduced.
- **Verification:** `alr build` clean; `tests/run-tests.sh`'s dedicated `Parse_Expression_Tests`
  driver (38/38) and the `gen-reference` public-surface tests both pass unchanged; full three-way
  gate green (`sdata` `make check` 727/727, `data-vandal` `make check` 149/149) — no new test
  needed, since `Parse_Expression` is already exercised indirectly by every `IF=` dataset option
  in both consumers' existing suites, and nothing about *what* it does changed, only *where its
  code lives*.

## Alternatives Rejected

- **Further decompose the nested helpers into their own sub-subunits** (e.g., `Advance` as a
  subunit of `Parse_Expression` itself). Ada permits nested subunit chains in principle, but
  `Parse_Expression` is not itself a separately-named compilation unit in the sense `separate`
  clauses require for a *nested* subprogram parent — the proven, lower-risk move (matching both
  prior extractions in this series) is a single mechanical lift of the whole function, not a
  speculative deeper decomposition with uncertain tooling support.
