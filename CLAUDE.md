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

See `tests/README.md` for what's in scope.

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

`SData_Core.Evaluator.Parse_Expression (Text : String)` is also part of the
public contract — it's how each consumer's parser hands SELECT expressions
back to the shared evaluator without needing to share AST types (per
[ADR-040](../sdata/doc/adrs.md)).

## Package Overview

- `SData_Core.Commands` — Execute_USE, Execute_SAVE, Execute_FPATH,
  Execute_OUTPUT, Execute_OUTPUT_Table, Execute_SELECT, Execute_KEEP,
  Execute_DROP, Execute_ARRAY, Execute_DIM, Execute_RUN,
  Execute_Rebuild_Filter, Execute_REPEAT, Execute_NEW,
  Execute_OPTIONS_{CSVDLM, Header, SAVEOVERWRT, TXTFMT, CHARSET,
  IEEE_Divide, Shell_Timeout}, Execute_Record_Error
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
the sdata repository:

- **`../sdata/doc/adrs.md`** — pre-extraction and boundary ADRs.
  ADR-039 covers this crate's extraction; ADR-040 the no-lexer/AST/parser
  rationale; ADR-041 the subscripted-column auto-detection; ADR-042 the
  `Execute_OUTPUT_Table` parallel entry point; ADR-043 per-application
  version constants.
- **`../sdata/doc/specs/2026-05-19-data-vandal-design.md`** — the full design
  spec for the data-vandal extraction that drove this crate's creation.
  Read first when reasoning about the consumer boundary.
- **`../sdata/doc/architecture.md`** — sdata's architecture doc, which now
  documents the three-crate layout and the package split.

Consult an ADR before proposing a structural change that might relitigate a
settled question.
