# sdata-core — Shared Data Layer and Evaluator

Ada 2012 Alire library crate. Holds the data layer, expression evaluator, and
the execution bodies of commands shared between the [sdata](https://github.com/jlries61/sdata)
interpreter and the [data-vandal](https://github.com/jlries61/data-vandal) application. Not a
standalone program — no executables, no `make check` at this level.

## Repository Layout (Important)

This is one of three sibling crates:

```
~/Develop/
├── sdata/          interactive interpreter — consumer of this crate
├── sdata-core/     this repository
└── data-vandal/    data degradation tool — also a consumer
```

Both consumers depend on this crate via an Alire path pin during development
(`[[pins]] sdata_core = { path = "../sdata-core" }`) plus a version constraint
(`sdata_core = "^0.1.0"`). The path pin overrides version resolution for local
builds; the constraint takes effect when sdata-core eventually publishes to the
Alire community index. **Until then, expect any developer working on sdata-core
to also have `~/Develop/sdata/` and `~/Develop/data-vandal/` checked out.**

### This file binds every session touching this crate, regardless of origin (ADR-0009)

Both consumers' own `CLAUDE.md` files correctly instruct their sessions to modify
`~/Develop/sdata-core/src/` directly for shared code — meaning a Claude Code session
rooted in `sdata` or `data-vandal`, not this repo, is routinely the one making the
change. **That session is bound by every rule in this file exactly as if it were
rooted here.** Concretely, before touching anything under this crate:

1. Read this file in full — do not carry over the originating repo's build,
   versioning, or documentation conventions by assumption; they differ (see
   §Versioning, §Documentation below, and `tests/README.md`).
2. Run the full three-way gate before committing: `alr build` here, then
   `make check` in **both** `../sdata` and `../data-vandal` (§Build & Test).
3. **Check `.ssd/current.yml` in *this* crate.** It is a separate, gitignored
   SSD workstream tracker from whichever repo the session started in — a
   session's own `.ssd/` has zero visibility into this one. If the change is
   non-trivial (not a one-line fix), add or update an entry here; don't let
   sdata-core work go untracked just because the session's home base was
   elsewhere. This exact gap — sdata-core changes landing without any SSD
   workstream tracking them — produced a ~6-week untracked gap in 2026-06/07
   (see `.ssd/milestones/2026-07-23-post-decomposition-baseline/`); it can
   recur just as easily from the consumer-session direction, not only from a
   forgotten sdata-core-rooted session.
4. Follow this crate's own version-bump and git-tag conventions (§Versioning)
   and documentation conventions (ADR numbering in `docs/decisions/`,
   `tests/README.md`'s driver table, `docs/api/reference.html` regeneration on
   `.ads` changes) — don't apply the originating repo's equivalents to
   sdata-core files.

See ADR-0009 for the rationale and the failure mode this codifies.

## Build & Test

```bash
alr build            # builds the library archive only
```

There is no test suite in this crate — testing is the consumers' responsibility.
**Every change to sdata-core must be validated against both consumer test
suites before committing:**

```bash
cd ~/Develop/sdata        && make check    # sdata's integration + unit suites
cd ~/Develop/data-vandal  && make check    # data-vandal's VANDALIZE integration suite
```

If either consumer regresses, fix sdata-core (or both consumers, if the change
is intentional) before committing.

**Documentation-only commits** — changes confined to `CLAUDE.md`, `tests/README.md`,
and similar non-build prose — do **not** require the consumer-suite validation above;
nothing buildable changed. The exemption does **not** apply once a commit touches
`src/`, the `tests/` drivers, `*.gpr`, `alire.toml`, or the `.github/workflows/` files.

### In-crate test driver

`tests/` contains a small set of standalone Ada drivers (Values, Parse_Expression,
Call_Function, Statistics, Commands) covering the pure-function subset of the
public API plus the Runtime-stateful command seam. They are
NOT a replacement for the consumer suites — they're a seconds-scale sanity
gate per audit Findings Beck B1/B2. Run with:

```bash
tests/run-tests.sh
```

`run-tests.sh` also runs `scripts/test-gen-reference.py` (Python stdlib, skipped
if `python3` is absent), the regression tests for the API-reference generator
described below. See `tests/README.md` for what's in scope.

### API reference generator

`scripts/gen-reference.sh` produces an HTML programmer's reference for the
public API straight from the `.ads` specs — it reads them as text (Python 3
stdlib only) rather than via the Ada toolchain, which is why it works where
GNATdoc 26.0 crashes on this crate's source closure. Output defaults to
`docs/api/reference.html`, a checked-in artifact — regenerate and commit it
whenever a public spec changes so the tracked copy stays in sync. Pass `--all`
to `gen-reference.py` to document every spec rather than just the
public-contract packages.

```bash
scripts/gen-reference.sh                 # -> docs/api/reference.html
```

### CI scope

`.github/workflows/build.yml` is a build-only smoke test (`alr build` on every
push and PR), plus the in-crate test driver run (`tests/run-tests.sh`).

`.github/workflows/consumer-tests.yml` automates the `sdata` half of the
manual validation above: it checks out sdata at a pinned tag as a sibling
and runs `make check` + `make fuzz-corpus` against the sdata-core SHA under
test. **`data-vandal` is intentionally not automated** because it is a private
repository and cross-repo checkout would leak build / test output into
public sdata-core Actions logs. `data-vandal` validation remains a manual
step that you must run locally before every commit.

The pinned sdata tag in `consumer-tests.yml` should be bumped on each new sdata
release, so the stability gate validates a *current* consumer (it silently lags
otherwise — keep this in step with sdata's releases):

```bash
git -C ../sdata tag --sort=-creatordate | head -1   # latest sdata tag
# Edit .github/workflows/consumer-tests.yml: set the `ref:` to that tag.
# Commit as `ci(consumer-tests): bump sdata pin to vX.Y.Z`.
```

## Public API — Stability Contract

The `SData_Core.Commands.Execute_*` procedures and `SData_Core.Config.Runtime`
mutable state are the public contract consumed by both applications.
**Changing their signatures or semantics breaks both consumers.** When such a
change is unavoidable:

1. Decide whether it warrants an ADR (significant semantic shift → yes).
2. Update both consumers' dispatch sites in the same logical change set.
3. Re-run both test suites.
4. Consider bumping sdata-core's version (see §Versioning).
5. **If step 2 can't land in the same sitting** (the consumer-side adoption is
   deferred to a later session, possibly days out), record it as pending work
   in *that consumer's own* `.ssd/current.yml`/`current.notes.yml` — not just
   this crate's. A session rooted in sdata or data-vandal has no visibility
   into this crate's notes and no reason to go looking for a breaking change
   it doesn't yet know exists; the reverse of the gap ADR-0009 closed (a
   consumer-rooted session not checking *this* crate's tracker) is a
   sdata-core-rooted session not writing to *the consumer's* tracker in the
   first place. Mirror the existing `archived_cross_repo_work` convention in
   `current.notes.yml` (see ADR-0001) for the sdata-core side of the record.

`SData_Core.Evaluator.Parse_Expression (Text : String)` is also part of the
public contract — it's how each consumer's parser hands SELECT expressions
back to the shared evaluator without needing to share AST types (per
[ADR-040](../sdata/doc/adrs.md)).

## Package Overview

- `SData_Core.Commands` — Execute_USE, Execute_SAVE, Execute_FPATH,
  Execute_OUTPUT, Execute_OUTPUT_Table, Execute_SELECT, Execute_KEEP,
  Execute_DROP, Execute_ARRAY, Execute_DIM, Execute_AGGREGATE,
  Execute_Commit_Step, Execute_RUN, Execute_Rebuild_Filter, Execute_REPEAT,
  Execute_NEW, Execute_OPTIONS_{CSVDLM, Header, SAVEOVERWRT, TXTFMT, CHARSET,
  IEEE_Divide, Shell_Timeout, Join_Warn_Threshold, WarnReserved},
  Warn_Reserved_Columns, Execute_Record_Error
- `SData_Core.Table` — column-store table + SQLite spill
- `SData_Core.Variables` — PDV, temp/permanent symbols, hold semantics,
  `Register_Subscripted_Columns` (auto-detect arrays from `name(n)` columns at
  USE time, per [ADR-041](../sdata/doc/adrs.md))
- `SData_Core.Values` — Value variant type (Numeric / Integer / String /
  Missing) + IEEE 754 infinity
- `SData_Core.Evaluator` (+ `Aggregate_Fns` / `Distrib_Fns` / `Misc_Fns` /
  `Nav_Fns` / `Numeric_Fns` / `String_Fns`) — expression evaluator and
  Parse_Expression
- `SData_Core.File_IO` (+ `CSV` / `ODF` / `OOXML` / `Helpers`) — read/write
- `SData_Core.CSV` — pure CSV tokeniser
- `SData_Core.Statistics` — aggregate / statistical helpers
- `SData_Core.Config` (+ `Runtime`) — startup constants + mutable interpreter
  state shared across the lifetime of a process
- `SData_Core.IO` — stdin/stdout/pager I/O
- `SData_Core.Signals` — SIGINT/SIGTERM cleanup
- `SData_Core.System` — shell execution + privilege detection

**Not in sdata-core:** lexer, AST, parser. Ada enumeration types are closed,
so `Token_Kind` / `Statement_Kind` / `Expression_Kind` cannot be shared across
applications — each consumer owns its complete grammar. See
[ADR-040](../sdata/doc/adrs.md) for the rationale.

## Compiler Settings

`sdata_core.gpr` adds `-gnatVn` to the Alire-managed switch set: validity
checks are disabled because this crate legitimately stores IEEE 754 infinity in
`Float` variables, which `-gnatVa` (in the Alire default profile) rejects as
invalid. Don't re-enable validity checks without first removing the infinity
usage from `SData_Core.Values`.

`sdata_core.gpr` also appends `-gnaty-m -gnaty-S`, disabling exactly two of the
otherwise-full `-gnaty…` style set: the 79-char max-line check (`-gnatym`) and
the no-statement-after-`then` check (`-gnatyS`). The crate's house style uses
lines past 79 (the license header alone is 91) and inline guard clauses
(`if Cond then return; end if;`) deliberately and pervasively; conforming the
code would be large, risky churn for no behavioural gain. Every other `-gnaty`
check stays on and the tree builds clean against them, so a genuinely new style
warning still stands out (Beck B3 in the milestone audit). The two switches are
appended in `sdata_core.gpr` (project-owned) rather than edited into the
Alire-generated `config/sdata_core_config.gpr`, which is left untouched.

A pre-build hook (`scripts/fix-mathpaqs.sh`) marks the upstream `mathpaqs`
project as `Externally_Built` because mathpaqs' generic specs are incompatible
with GNAT library projects. The script is idempotent.

## Versioning

sdata-core has an independent version lifecycle (per
[ADR-043](../sdata/doc/adrs.md)). Bump in `alire.toml` only — there are no
Ada-level version constants, because no code in sdata-core currently needs to
display "sdata-core version X.Y.Z" to users. After bumping, tag with
`git tag -a vX.Y.Z -m "Version X.Y.Z"`.

Each release should be coordinated with consumers: if a sdata-core release
changes a `Commands` signature or removes a runtime field, the consumers must
update their dispatch code and their `^X.Y.Z` constraints in the same logical
change.

## Reference Documents

### sdata-core's own ADRs

Decisions made **inside** sdata-core (after extraction) live in
[`docs/decisions/`](docs/decisions/README.md). The index there lists every
ADR with status and date. New decisions go here.

### Inherited from sdata

Decisions about the extraction itself and the boundary contract still live in
the sdata repository. **Important:** sdata's own ADR series (`ADR-NNN`, distinct
numbering from this crate's `ADR-NNNN`) did not stop at the extraction —
sdata keeps recording new decisions there even when they're actually about
*this crate's* public surface, because the deciding session was rooted in
sdata. Several of this crate's own source comments cite these by number
(`grep -rn "ADR-0[0-9][0-9]" src/` to find current citations) with no local
copy to resolve them against, so treat sdata's ADR file as a second,
still-growing inherited series, not a closed one:

- **`../sdata/doc/adrs.md`** — pre-extraction and boundary ADRs (ADR-039
  covers this crate's extraction; ADR-040 the no-lexer/AST/parser rationale;
  ADR-041 the subscripted-column auto-detection; ADR-042 the
  `Execute_OUTPUT_Table` parallel entry point; ADR-043 per-application
  version constants) **plus later ADRs about this crate's own command
  surface**: ADR-045 (promoting the reserved-keyword warning here), ADR-046
  (`Execute_AGGREGATE`), ADR-047 (`Execute_TRANSPOSE`), ADR-048
  (`Execute_STATS`) — all cited directly in `commands.ads`/`commands.adb`.
  This list (through ADR-049 as of 2026-07-24) **will already be behind** by
  the time you read it if sdata has added a command since; check sdata's own
  ADR index table for anything past the last number named here before
  assuming this list is complete.
- **`../sdata/doc/specs/2026-06-01-aggregate-design.md`** and
  **`2026-06-01-transpose-design.md`** — the design specs `commands.adb`'s own
  comments point to ("see the design spec sec N") for `Execute_AGGREGATE` /
  `Execute_TRANSPOSE`. Read these, not just the ADR, before changing either
  procedure's validation order or error catalog.
- **`../sdata/doc/specs/2026-05-19-data-vandal-design.md`** — the full design
  spec for the data-vandal extraction that drove this crate's creation.
  Read first when reasoning about the consumer boundary.
- **`../sdata/doc/architecture.md`** — sdata's architecture doc, which now
  documents the three-crate layout and the package split.

Consult an ADR before proposing a structural change that might relitigate a
settled question — checking only this crate's own `docs/decisions/` is not
sufficient; the decision may live in sdata's series instead (see above).
