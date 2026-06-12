# Architecture Decision Records

This directory holds ADRs for decisions made **within** sdata-core after its
extraction from the sdata interpreter.

ADRs about the extraction itself, the boundary contract, and pre-extraction
design choices live in the sdata repository at
[`../sdata/doc/adrs.md`](https://github.com/jlries61/sdata/blob/main/doc/adrs.md).
The relevant historical entries there are:

- **ADR-039** — extraction of sdata-core as a separate Alire crate
- **ADR-040** — sdata-core deliberately holds no lexer / AST / parser (closed
  Ada enums can't be shared across applications)
- **ADR-041** — auto-detection of subscripted columns at USE time
- **ADR-042** — `Execute_OUTPUT_Table` as a parallel entry point for the
  data-vandal-style "OUTPUT writes the dataset" semantics
- **ADR-043** — per-application version constants (sdata-core's version is
  independent of sdata's)

Use the sdata-side ADRs for "why is sdata-core shaped the way it is at the
boundary?" Use the ones in *this* directory for "why did sdata-core make
decision X *after* extraction?"

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [ADR-0001](ADR-0001-adopt-ssd-with-library-crate-adaptations.md) | Adopt SSD methodology with library-crate adaptations | Accepted | 2026-05-22 |
| [ADR-0002](ADR-0002-pin-consumer-tests-to-sdata-tags.md) | Pin consumer-tests CI to sdata release tags | Accepted | 2026-05-26 |
| [ADR-0003](ADR-0003-exclude-data-vandal-from-ci.md) | Exclude data-vandal from consumer-tests CI | Accepted | 2026-05-22 |
| [ADR-0004](ADR-0004-commands-encapsulates-runtime-mutations.md) | Commands package is the sole write surface for Config.Runtime | Accepted | 2026-05-26 |
| [ADR-0005](ADR-0005-options-validation-length-only-in-core.md) | OPTIONS validation: length in core, semantics in consumers | Accepted | 2026-05-26 |
| [ADR-0006](ADR-0006-resolve-use-defaults-in-core.md) | USE-default resolution centralized in core via Resolve_Use_Defaults | Accepted | 2026-06-11 |
| [ADR-0007](ADR-0007-decompose-table-package.md) | Decompose SData_Core.Table behind an unchanged facade (Columns + Backing_Store + Sorting + Grouping) | Accepted | 2026-06-12 |

## Numbering

ADRs in this directory use four-digit zero-padded numbers (`ADR-NNNN-…`)
starting at `0001`. This is independent of sdata's `ADR-039`-style numbering;
the two series do not overlap by design. When a sdata-side ADR is materially
relevant to a sdata-core decision, link to it explicitly.

## Format

Roughly the Michael Nygard template:

1. **Status** — Proposed / Accepted / Deprecated / Superseded by ADR-NNNN
2. **Context** — the problem and the forces in play
3. **Decision** — what we chose
4. **Consequences** — positive, negative, and neutral; trade-offs incurred

Each ADR opens with YAML frontmatter (date, status, supersedes/superseded-by
pointers if any, related PR / audit-finding references) so tooling can read
the metadata without parsing prose.
