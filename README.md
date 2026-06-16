# sdata-core

[![Build](https://github.com/jlries61/sdata-core/actions/workflows/build.yml/badge.svg)](https://github.com/jlries61/sdata-core/actions/workflows/build.yml)
[![Consumer Tests](https://github.com/jlries61/sdata-core/actions/workflows/consumer-tests.yml/badge.svg)](https://github.com/jlries61/sdata-core/actions/workflows/consumer-tests.yml)

Shared data layer and expression evaluator for the
[sdata](https://github.com/jlries61/sdata) interpreter and the
**data-vandal** data-degradation tool. An Ada 2012
[Alire](https://alire.ada.dev/) library crate holding the data layer, the
expression evaluator, and the execution bodies of the commands both
applications share.

> **This is a library, not a program.** It builds to an archive only — there
> are no executables and no top-level test runner. Testing is the consumers'
> responsibility (see [Testing](#testing)).

## Repository layout

sdata-core is one of three sibling crates that are developed together. The
consumers depend on it via an Alire path pin during development, so a working
checkout normally looks like this:

```
~/Develop/
├── sdata/          interactive interpreter — consumer
├── sdata-core/     this repository
└── data-vandal/    data-degradation tool — consumer
```

## Building

```bash
alr build
```

A pre-build hook (`scripts/fix-mathpaqs.sh`, run automatically by Alire) marks
the upstream `mathpaqs` project as externally built; it is idempotent.

## Testing

There is no test suite at this level. Two layers of validation apply:

- **In-crate drivers** — a seconds-scale sanity gate over the pure-function
  subset of the public API plus the Runtime-stateful command seam, and the
  documentation-generator tests:

  ```bash
  tests/run-tests.sh
  ```

- **Consumer suites** — the real gate. Every change that touches buildable
  files must pass both consumers before it is committed:

  ```bash
  cd ~/Develop/sdata        && make check
  cd ~/Develop/data-vandal  && make check
  ```

## Package overview

| Package | Responsibility |
|---|---|
| `SData_Core.Commands` | `Execute_*` bodies for the shared command set (USE, SAVE, SELECT, KEEP, DROP, OPTIONS, …) |
| `SData_Core.Table` | Column-store table with SQLite spill |
| `SData_Core.Variables` | Program Data Vector, temp/permanent symbols, subscripted-column auto-detection |
| `SData_Core.Values` | `Value` variant type (Numeric / Integer / String / Missing) + IEEE 754 infinity |
| `SData_Core.Evaluator` (+ `*_Fns`) | Expression evaluator and `Parse_Expression` |
| `SData_Core.File_IO` (+ `CSV` / `ODF` / `OOXML`) | Reading and writing datasets |
| `SData_Core.Statistics` | Probability-distribution and statistical helpers |
| `SData_Core.Config` (+ `Runtime`) | Startup constants and mutable per-run interpreter state |
| `SData_Core.IO` / `Signals` / `System` | stdin/stdout/pager I/O, signal cleanup, shell execution |

**Not in sdata-core:** the lexer, AST, and parser. Ada enumeration types are
closed, so each consumer owns its complete grammar (see
[ADR-040](https://github.com/jlries61/sdata/blob/main/doc/adrs.md)).

## API reference

An HTML programmer's reference for the public API is generated directly from
the package specs:

```bash
scripts/gen-reference.sh          # writes docs/api/reference.html
```

The generator reads the `.ads` specs as text (Python 3 standard library only —
no Ada toolchain required). Pass `--all` to `scripts/gen-reference.py` to
document every spec rather than just the public-contract packages.

## Public API and versioning

The `SData_Core.Commands.Execute_*` procedures, the `SData_Core.Config.Runtime`
state, and `SData_Core.Evaluator.Parse_Expression` form the stability contract
consumed by both applications — changing their signatures or semantics breaks
both consumers and must be coordinated with them. sdata-core carries an
independent version (bumped in `alire.toml`).

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — detailed contributor and build guidance.
- [`docs/decisions/`](docs/decisions/README.md) — architecture decision records
  made inside sdata-core.
- Boundary and extraction ADRs live in the sdata repository
  ([`doc/adrs.md`](https://github.com/jlries61/sdata/blob/main/doc/adrs.md)).

## License

GPL-3.0-only WITH GCC-exception-3.1. See [LICENSE](LICENSE).
