---
id: ADR-0024
title: "USE-time subscripted-column auto-detection skips a base name that already exists as a scalar, instead of aborting"
status: Accepted
date: 2026-09-05
related:
  - ADR-0012-scalar-array-storage-class-hard-error.md
  - ADR-0015-array-kind-replacement-symmetric-rules.md
  - ADR-041 (../../../sdata/doc/adrs.md) — subscripted-column auto-detection
  - jlries61/sdata-core#117
---

# ADR-0024: USE-time subscripted-column auto-detection skips a base name that already exists as a scalar, instead of aborting

## Status

Accepted.

## Context

GitHub issue [jlries61/sdata-core#117](https://github.com/jlries61/sdata-core/issues/117):
`Register_Subscripted_Columns` (ADR-041's USE-time array auto-detection,
`SData_Core.Variables`) scans the loaded columns for the `base(n)` naming
pattern and, for each detected base name, unconditionally calls `Dim_Array
(Base, Min, Max, False)` — with no check for whether `Base` is *itself* also
a literal loaded column (or a pre-existing temporary variable).

Since PR #116 (ADR-0012's PC-2 fix), `Dim_Array` rejects creating an array
over an existing scalar name (`Table.Has_Column` or `Temp_Symbols.Contains`),
raising `Script_Error`. That guard is correct for what it was built for —
user-typed `LET`/`SET`/`DIM` silently shadowing an existing name — but
`Register_Subscripted_Columns` now inherits the same rejection for a
collision that isn't user-typed at all: it's just the shape of the loaded
file. A CSV with columns `Q,Q(1),Q(2),Q(3)` now aborts the entire `USE` with
`Script_Error`, and nothing loads.

Before PR #116, the identical collision didn't raise — `Register_Subscripted_
Columns` silently registered `Q` as an array while `Table.Has_Column("Q")`
remained true for the literal column, making that column's actual loaded
values unreachable through ordinary `PRINT Q` syntax (the array's element
lookup shadowed it). Neither behavior is correct; this ADR decides the
question the issue explicitly left open.

Two call sites share `Register_Subscripted_Columns` and are both affected
identically: `Execute_USE` (`SData_Core.Commands`) and `Commit_Reshaped_Table`
(the shared epilogue for `AGGREGATE`/`TRANSPOSE`/`STATS`, same file) — a
reshape command whose output happens to produce both a bare outvar column and
its own `name(n)`-shaped siblings hits the identical bug.

## Decision

`Register_Subscripted_Columns`'s per-base-name registration loop skips
auto-registration for any `Base` that already exists as a scalar —
`Table.Has_Column (Base)` or `Temp_Symbols.Contains (Base)` — instead of
calling `Dim_Array` (and instead of the pre-#116 silent-shadow behavior).
`Base`, `Base(1)`, … `Base(n)` are left exactly as they arrived: ordinary,
independent columns, still fully present in the table (`SAVE`, `KEEP`/`DROP`,
`TRANSPOSE` all see them as usual). **They are not, however, reachable
through *bare* `Base(n)` expression syntax** — that syntax is unavoidably
ambiguous with array-element/function-call syntax once `Base` isn't a
registered array, and errors as "unknown function" if attempted (verified
empirically against the built interpreter, not assumed). They remain
individually reachable through ordinary `PRINT`/expression syntax via the
*existing* backtick quoted-identifier form (design.md §3.2 — the same escape
hatch a reserved-keyword or embedded-space column name already requires):
`` `Base(1)` ``, taken verbatim, is not parsed as array/function syntax at
all. This is not a new limitation this decision introduces — it is the same
one every column whose literal name doesn't fit the bare-identifier grammar
already has, and the runtime notice says so:

> `USE: not registering "<BASE>" as an array from <BASE>(1)..<BASE>(n): "<BASE>" already exists as a scalar variable. The "<BASE>(n)" columns are still loaded; reference them with the backtick form, e.g. \`<BASE>(1)\`.`

Both storage classes are checked (not just `Table.Has_Column`, which is all
the issue's own reproduction exercises) for the same reason `Dim_Array`'s own
guard checks both: a pre-existing `SET`-created temporary variable named
`Q`, present when `USE` loads a file whose columns include `Q(1)..Q(n)` but
no literal `Q` column, hits the identical `Dim_Array` rejection today and
would abort `USE` exactly the same way. Fixing only the literal-column case
described in the issue's reproduction and leaving the temp-variable case
raising would be closing this defect at the wrong granularity (per this
project's own established review discipline — see `code-reviewer/SKILL.md`
§ "Phase 3.5" item 8, "was the class swept, or only the instance").

## Rationale

- **Rejects Option (a) — keep failing `USE` loudly.** `Q` alongside
  `Q(1)/Q(2)/Q(3)` is a legitimate, plausible column shape for a data file
  the user did not construct with sdata's `ARRAY`/`DIM` semantics in mind —
  it is *sdata's own auto-detection heuristic* that assumes any `base(n)`
  group implies an array, not a claim about the source file's intent.
  Aborting the entire load (losing every other column too) because an
  optional convenience feature's assumption doesn't hold is a disproportionate
  failure mode: the user did nothing wrong, and needs their data loaded far
  more than they need automatic array detection for one particular column
  name.
- **Rejects Option (c) as a distinct path — rename/warn.** A rename (e.g.
  auto-renaming the bare `Q` to something else) invents new column-naming
  behavior nobody asked for and would itself be a silent, surprising
  transformation of the user's data schema — worse than either failing or
  skipping. The "warn" half of (c) is retained, but attached to Option (b),
  not as a separate path: skip the array, but say so.
- **Selects Option (b) — skip auto-registration for that base name, warn.**
  This is the minimal-surprise resolution: `USE` succeeds, every column loads
  under its own literal name and remains individually reachable (bare syntax
  for the plain `Base`, backtick syntax for the `Base(n)` siblings — exactly
  as it would if `Register_Subscripted_Columns` didn't exist at all), and the
  printed notice tells the user why no array appeared for that one base name
  and how to reach the individual columns, in case they expected one. A user
  who genuinely wants `Q(1)/Q(2)/Q(3)` treated as an array despite the
  colliding bare column can still say so explicitly — `DROP Q` (or `UNSET Q`
  if it's a temp var) then re-run detection is already possible with
  existing primitives; no new syntax is needed for this ADR.
- **`Put_Line`, not `Put_Line_Error`; unconditional, not OPTIONS-gated.**
  Matches this exact function's own immediately-adjacent ADR-0015 notice
  (`Has_Array (Base) and then ... Kind = Virtual_Array` → "USE: replacing
  virtual array…") rather than reaching across the file to `Warn_Reserved_
  Columns`' different convention. Both are "here's what USE-time
  auto-detection did" notices in the same function and loop; consistency
  with the nearer precedent wins over consistency with a more distant one
  addressing a conceptually different question (reserved-keyword collision,
  which is about the name itself, not about a competing storage-class
  registration).

## Consequences

**Positive**

- Closes #117: a dataset shaped with both a bare column and its own
  subscripted siblings loads successfully, with every column individually
  reachable by its literal name (bare for `Base`, backtick-quoted for
  `Base(n)`) — matching what would happen if `Register_Subscripted_Columns`
  didn't exist for that base name at all.
- No silent shadow-state: the printed notice means a user who *did* expect
  an array finds out immediately, from the same `USE` command, rather than
  discovering it later via a confusing `PRINT`/`LET` result (the pre-#116
  failure mode this ADR also avoids reintroducing).
- No public API change: `Register_Subscripted_Columns` and `Dim_Array`
  keep their existing signatures; `Execute_USE`'s signature is untouched.
  Single-repo — neither consumer needs a dispatch-site update.

**Negative**

- A dataset that genuinely intends `Q(1)/Q(2)/Q(3)` as an array *and*
  happens to also carry an unrelated bare `Q` column (e.g. a summary/total
  column the source system named coincidentally) gets no automatic array —
  the user must `DROP`/`UNSET` the bare column and re-trigger detection
  manually if they want array semantics. This is the accepted cost of
  Option (b) over a "smarter" heuristic (e.g. treating `Q` as the array's
  own implicit total) that ADR-041 never specified and this ADR is not
  introducing now.
- Two independent storage-class checks (`Table.Has_Column` /
  `Temp_Symbols.Contains`) are now evaluated once per detected base-name
  group in `Register_Subscripted_Columns`, in addition to the checks
  `Dim_Array` itself already performs for the base names that do proceed —
  a negligible cost (this loop already runs once per `USE`/reshape, not
  per row).
- The `Base(n)` columns require the backtick form for ordinary expression
  reference once auto-registration is skipped; bare `Base(n)` syntax errors
  ("unknown function") rather than resolving, because that syntax is
  inherently ambiguous with array/function-call syntax once `Base` isn't a
  registered array. Not a new class of limitation (any column whose literal
  name doesn't fit the bare-identifier grammar already requires backticks),
  but worth naming plainly rather than leaving implicit: a user who only
  reads the printed notice's first sentence and not its second could still
  be surprised by the first bare-syntax attempt. The notice's second
  sentence exists specifically to close that gap.

## Verification note: `Commit_Reshaped_Table`'s exposure to this bug is real but not currently constructible

The fix lives in `Register_Subscripted_Columns`, shared by both call sites, so `AGGREGATE`/
`TRANSPOSE`/`STATS` output is covered by construction. But an attempt to write a dedicated
regression test reproducing the collision *through* `Commit_Reshaped_Table` specifically (as
opposed to `Execute_USE`) found that every avenue tried is independently blocked by a *different*,
pre-existing guard, before the offending shape can ever reach `Register_Subscripted_Columns`:

- An `AGGREGATE` outvar name reused twice (`Q=SUM(Y) Q=MEAN(X)`) is rejected as a duplicate outvar
  name.
- An `AGGREGATE`/`TRANSPOSE` outvar or `/ARRAY=` name matching an active `BY` variable is rejected
  as a BY/outvar collision (`AGGREGATE: outvar 'Q' collides with active BY variable` /
  `TRANSPOSE: output column name 'Q' collides with active BY variable`).
- A `TRANSPOSE /ID=` value shaped like `Q(1)` (i.e., matching the very `base(n)` pattern this ADR
  is about) is rejected outright as "not a legal column identifier" before it can ever become an
  output column name.

No fourth avenue was found. This does **not** make the shared-function fix wrong or the second call
site's coverage moot — a future change to any one of those three independent guards could reopen
the path, and the fix would already be in place waiting for it — but it does mean no test currently
exercises `Register_Subscripted_Columns`'s new guard via `Commit_Reshaped_Table`, only via
`Execute_USE`. Recorded here rather than silently omitted, so a future reader doesn't wonder why.

## Alternatives Rejected

See "Rationale" above for (a) and (c). A fourth alternative — teach
`Dim_Array` itself to silently no-op (instead of raising) when called from
`Register_Subscripted_Columns` specifically — was rejected because it would
require `Dim_Array` to distinguish its caller's identity (auto-detection vs.
a user-typed `DIM` statement), which is exactly the kind of caller-aware
branching this codebase has avoided elsewhere; the guard belongs in
`Register_Subscripted_Columns`, which already knows it is doing best-effort
auto-detection, not in `Dim_Array`, whose ADR-0012 hard-error contract must
stay unconditional for its actual (user-typed) callers.

## Related

- ADR-0012 (`scalar-array-storage-class-hard-error`) — the guard this
  decision works around by skipping the call, not by weakening the guard.
- ADR-0015 (`array-kind-replacement-symmetric-rules`) — the notice-message
  convention this decision's warning follows.
- `../../../sdata/doc/adrs.md` ADR-041 — the auto-detection feature this
  decision refines.
- `jlries61/sdata-core#117` — the issue this decision resolves.
