---
id: ADR-0026
title: "CSV/ODF/OOXML I/O: user-declared MISSING-value tokens (read-side list, write-side single token; amended: ODF/OOXML read-side support)"
status: Accepted (amended — see Amendment below)
date: 2026-09-26
related:
  - ADR-0019-scan-window-any-nonnumeric-forces-character.md
  - ADR-0020-coercion-warning-cap.md
  - ADR-0027-declared-column-types.md
  - ../../../sdata/doc/adrs.md (sdata ADR-083 -- the language-surface decision this implements)
  - ../../../sdata/.ssd/features/missing-value-tokens/01-architect.md
  - ../../../sdata/.ssd/features/missing-value-tokens/02-systems-designer.md
  - ../../../sdata/.ssd/features/missing-spreadsheet-read/00-brief.md
  - ../../../sdata/.ssd/features/missing-spreadsheet-read/01-architect.md
  - ../../../sdata/.ssd/features/missing-spreadsheet-read/02-systems-designer.md
---

# ADR-0026: CSV/ODF/OOXML I/O gains user-declared MISSING-value tokens

## Status

Accepted.

## Context

sdata's `USE` and `SAVE` gained new `/MISSING=` options (sdata ADR-083) so a script can declare which
literal strings mean "missing" in its data, rather than being limited to the two built-in markers `""`
and `"."`. This repository owns the actual file-I/O implementation both commands drive
(`SData_Core.File_IO.CSV`/`.ODF`/`.OOXML`, `SData_Core.Commands.Execute_USE`/`Execute_SAVE`,
`SData_Core.Config.Runtime`'s pending-`SAVE` state).

The motivating problem (see sdata ADR-083 for the full narrative) was a position-dependent "cliff":
`Infer_Column_Types`'s NSCAN-row scan window and `Process_Line_Direct`'s per-row load each independently
hardcoded the same two-literal check (`F = "" or else F = "."`), so an *undeclared* sentinel like `N/A`
was handled completely differently depending on whether it happened to land inside or outside the scan
window. ADR-0019's scan-window rule itself is correct and unchanged by this ADR; the gap this ADR closes
is that sdata had no way to be told a value was an *expected* sentinel rather than an anomaly.

## Decision

**Read side (`Parse_CSV` only).** New parameter `Missing_Tokens : String := ""`, a comma-separated list.
Split exactly once per `Parse_CSV` call, before either loop runs, using the existing quote-aware CSV
field splitter (`SData_Core.CSV.Split_Indices`) and unquoter (`CSV_Unquote`) — the same pair a CSV row's
own fields already go through — with the delimiter **hardcoded to `","`**, deliberately independent of
the call's own `Delimiter` parameter (a pipe-delimited file's `/DLM="|"` must not change how the token
list itself is split). Each split token is then trimmed of whitespace, matching the treatment a header
column name already gets in this same procedure. The resulting token set is consulted by a single
predicate, `Is_Declared_Missing`, called identically from `Infer_Column_Types`'s scan loop and
`Process_Line_Direct`'s per-row load loop — the single-shared-predicate structure is the direct fix for
the asymmetry described above; it is not merely "both loops happen to agree today," it is that both
loops call the same function. A field matching a declared token is missing in both places, with **no**
per-value warning (unlike the pre-existing `Coercion_Warn_Cap`-gated "non-numeric value ... stored as
missing" warning, which is unchanged for a genuinely undeclared anomaly) — instead, one summary line is
printed once per `Parse_CSV` call, if the count is non-zero: `Note: "<file>": N value(s) matched a
declared MISSING token`.

**Numeric columns only** (amended 2026-09-25 — user ruling closing sdata code review round 1, MAJOR-1).
The per-row call site is guarded by `Col_Types (Field_Count) /= Col_String`, so a declared token is
honored in a numeric or integer column and ignored in a character one, where the field is stored as
ordinary text instead. The scan-window call site needs no such guard: `Infer_Column_Types` only
consults it for a column whose type is still undetermined, which by construction is a numeric
candidate. The first implementation applied the token to every column regardless of type — reviewed as
a silent data-loss risk, since a script declaring `MISSING="NA"` for one numeric column would also
erase `NA` from an unrelated `CODE$` column where it is a legitimate value (Nebraska's postal code).
Scoping to numeric columns keeps the mechanism aimed at the type-inference cliff it exists to close,
which only arises for a column whose type is being inferred in the first place.

`Parse_ODF`/`Parse_OOXML` are **not** given this parameter. Neither has an `Nscan_Rows`-equivalent
parameter today (confirmed by reading both `.ads` files before starting) — their own type inference is a
narrower, row-1-only rule (see ADR-0019's "Alternatives Rejected" for the prior finding that this is a
distinct, unaudited gap). Adding declared-token read support to a reader whose inference story hasn't
been scoped risks exactly the kind of undertested corner ADR-0019's own follow-up found there once
already; deferred as a named candidate follow-up, not silently dropped.

**Write side (`Write_CSV`, `Write_ODF`, `Write_OOXML`).** New parameter `Missing_Token : String := ""`,
used verbatim — **never split**, regardless of whether it contains a comma — for a missing cell. Default
(`""`) reproduces today's behavior exactly: `Write_CSV` had no branch for `Val_Missing` (the field was
left empty by falling through the `if/elsif` chain); `Write_ODF` wrote `<table:table-cell/>`; `Write_OOXML`
did nothing (`when Val_Missing => null;`). All three now branch on `Missing_Token /= ""`, writing an
inline string cell (ODF/OOXML) or a `CSV_Quote`-escaped field (CSV) only when a token was given.

**Single-target `SAVE` state threading.** `Execute_SAVE` gained a `Missing_Token` parameter, stored via a
new `Config.Runtime.Internal.Set_Save_Missing_Token` / `Config.Runtime.Save_Missing_Token`/
`Save_Missing_Token_Len` accessor pair, following the exact existing pattern for `Save_Charset`
(a `String`-buffer capacity-limited field, not `Save_Decimals`'s bare `Integer`, since a token is text).
`Flush_Pending_Save` (called from `Execute_RUN`) reads it back and passes it to `Open_Output`, alongside
the pre-existing `Save_Decimals` read at that same call site. **This call site is positional, not named**
(`Open_Output (path, fmt, sheet, dlm, header, overwrite, charset, decimals)`) — adding `Missing_Token`
as `Open_Output`'s ninth parameter (before the existing, always-defaulted `View`) keeps this call
source-compatible without modification if left unupdated, but it was updated anyway to actually thread
the new value through; a positional call left unmodified would have compiled cleanly while silently
never honoring `/MISSING=` for the legacy single-target `SAVE` path, which is exactly the class of defect
`code-reviewer/examples.md` §8 (Edge Case Inventory) warns a class-vs-instance fix can leave behind.

**Multi-target `SAVE`.** sdata's own multi-target flush loop (in its interpreter, not this repository)
reads `Missing_Val`/`Missing_Len` directly off each target's own `Spec_Options` snapshot (`T.Opts`,
copied at `SAVE`-parse time from the parser's AST) and passes it to `Open_Output` per target — this
repository's `Open_Output`/`Write_*` signatures are the same either way; there is no dedicated
multi-target-specific procedure in `SData_Core.Commands` to change.

**One `Missing_Spec` capacity constant**, `SData_Core.Max_Missing_Spec_Len := 256`, shared by both the
read-side list and the write-side single token (sized for a handful of short sentinel tokens, e.g.
`"NA,N/A,NULL,-999,#N/A"` is 21 characters) rather than two differently-sized constants — the two
directions' fields happen to need the same generous upper bound, and one constant is simpler to reason
about than two whose difference in size would otherwise need its own justification.

## Rationale

Reusing `Split_Indices`/`CSV_Unquote` for the read-side list, rather than a naive `,`-split, gives quoted
tokens (a token containing a literal comma) for free, with no second quoting dialect to design or
document — the same escaping rules a CSV row's own fields already follow apply to the `MISSING=` list.
Hardcoding the list's own separator to `,` rather than reusing the file's `Delimiter` was a deliberate,
explicit choice, not an oversight — the two are conceptually unrelated (one is a property of the input
file's format, the other is fixed syntax of the `MISSING=` option itself), and reusing `Delimiter` would
have silently broken on a pipe- or tab-delimited file.

A single shared predicate for the read side (rather than two structurally-similar-but-separately-written
checks) is the actual fix for the cliff this feature exists to close, not merely a style preference: the
original cliff existed *because* the scan-window loop and the per-row load loop each independently
hardcoded the same two-literal comparison, and one shared call site is what makes it structurally
impossible for the new declared-token check to drift the same way in the future.

## Consequences

**Easier**: a script with a known sentinel value no longer needs to work around sdata's scan-window
heuristic — declaring the token makes the column behave consistently regardless of the anomaly's row
position, and `SAVE ... /MISSING="NA"` followed by `USE ... /MISSING="NA"` round-trips missing values
through the token instead of through blank/`.`.

**Harder / disclosed limitation**: ODF/OOXML gain the write-side token but not the read-side declared-token
recognition — a script relying on `/MISSING=` for spreadsheet *input* gets no effect (not an error;
`Open_Input` simply never threads `Missing_Tokens` to `Parse_ODF`/`Parse_OOXML`, which don't accept it).
A user who declares a token that happens to equal a real data value gets that value silently converted
to missing with no per-value warning — the one-summary-line count is the only visibility, by design (a
declared token is not an anomaly).

**No version-bump/migration concern for this repository specifically** — sdata-core has no independent
release process gate beyond its own `alr build` and the two-consumer local gate (this repository's
CLAUDE.md); the sdata-side version bump (if any) is tracked there, not here.

## Alternatives Rejected

**A separate `Missing_Read_Tokens`/`Missing_Write_Token` pair of AST-adjacent types, or a
`Ada.Containers.Vectors` of `Unbounded_String` threaded from the sdata parser** — rejected; sdata's own
AST layer deliberately has no heap-allocated fields (a project-wide, existing convention), and this
repository already has vector types and a splitter in scope for exactly this shape of work, so splitting
belongs here, not in sdata's parser.

**Trimming a data field's own value for MISSING= comparison purposes (in addition to trimming the
declared token)** — rejected; the existing `""`/`"."` checks compare a field's value exactly as
`CSV_Unquote` leaves it, with no trim. Trimming only the *token* (matching how a header column name is
already trimmed) adds no new whitespace-sensitivity to data comparison, which trimming the field value
too would have.

**Passing `Missing_Tokens` through to `Parse_ODF`/`Parse_OOXML` even without their own scan-window
concept, treating any declared-token match on read as missing regardless of row position** — deferred,
not rejected outright; flagged as a candidate follow-up once their own type-inference gap (row-1-only,
distinct from CSV's NSCAN-window rule) is itself scoped and audited, per ADR-0019's own unresolved
"Alternatives Rejected" item.

## Amendment (2026-09-26): ODF/OOXML read-side support

The precondition this ADR's original Context named — "a reader whose inference story hasn't been
scoped" — is closed. ADR-0027 (`/TYPES=`) subsequently gave both spreadsheet readers exactly the
machinery this deferral was waiting on: `Col_Locked` (a lock equivalent to CSV's `Col_Determined`) and
a `Target_Type`-aware `Get_Cell_Value`. `Parse_ODF` and `Parse_OOXML` now accept `Missing_Tokens`,
closing the "Harder / disclosed limitation" above: `/MISSING=` has an effect on spreadsheet input.

**Decision (amendment):** the read-side token-list parser and match predicate, previously private to
`Parse_CSV`, move into `File_IO.Helpers` as `Missing_Token_Vecs` / `Parse_Missing_Tokens` /
`Is_Declared_Missing` — unchanged in substance, shared by all three readers, mirroring the exact
discipline ADR-0027 already established for `Declared_Vecs`/`Parse_Declared_Types`. Both spreadsheet
readers' `Get_Cell_Value` gain a `Check_Missing : Boolean := False` parameter: the declared-missing
check sits immediately after the existing `Inf` resolution and before the `Real'Value` coercion
attempt, so a match never emits a coercion warning, and — being unconditional on `Coerce_To_Target` —
applies equally to the row-1 schema probe, which is what makes a declared token never force the column
to character there, the direct spreadsheet analogue of the CSV scan-window rule this ADR already
established. The one-summary-line counter is incremented only when `Col_Name /= ""`, the exact
convention `Coercion_Warn_Count` already uses to tell the schema probe apart from the real per-cell
load, so a row visited by both (row 1, on both readers) is not double-counted.

**Finding surfaced during design review, fixed before implementation:** `Get_Cell_Value`'s original
proposed check was unconditional across every caller. OOXML's `Collect_OOXML_Headers` reuses
`Get_Cell_Value` to read the **header** row — a caller neither this ADR's original scope nor ADR-0027's
own work had reason to consider, since neither touched header-name collection. An unconditional check
would have let a header cell whose text equals a declared token (`NA`, this ADR's own running example)
be silently replaced with a synthetic `COLn` name. `Check_Missing` defaults to `False` specifically so
`Collect_OOXML_Headers` is unaffected; every other call site in both readers passes `True` explicitly.
ODF's own header reader never calls `Get_Cell_Value` at all and was never at risk, but gained the same
parameter anyway so the two readers' `Get_Cell_Value` signatures stay identical in shape — a future
caller, in either reader, inherits the safe default automatically rather than needing to rediscover this
finding. Regression test: a column literally named `NA`, `/MISSING="NA"` declared for a different,
numeric column in the same file; verified as a genuine catch by temporarily reintroducing the
unconditional check and confirming the OOXML case fails (renames the column `COL1`) before reverting.

**Consequences (amendment):** the "Harder / disclosed limitation" bullet above is closed for the
declared-token-recognition half; the "no per-value warning" and "one-summary-line visibility" properties
now hold identically across all three formats. Scope is otherwise unchanged: numeric columns only,
same wording, same non-per-value-warning behavior, same composition rule with `/TYPES=` (a column
declared character via either mechanism stores a declared token as ordinary text, symmetric with the
numeric case, since `Target_Type = Col_String` returns before `Check_Missing` is ever consulted).
