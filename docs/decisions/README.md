# Architecture Decision Records

This directory holds ADRs for decisions made **within** sdata-core after its
extraction from the sdata interpreter — but it is **not** the complete record of
post-extraction decisions about this crate. sdata's own ADR series
(`../sdata/doc/adrs.md`, numbered `ADR-NNN` — distinct from this directory's
`ADR-NNNN`) keeps growing after the extraction, and several of those later
entries are decisions about *this crate's* public surface (`Commands`,
`Evaluator`), recorded there simply because the deciding session was rooted in
sdata. **Check both series** before assuming a structural question is settled
or unsettled; this crate's own source comments cite sdata's ADRs directly
(`grep -rn "ADR-0[0-9][0-9]" src/`) with no local copy to resolve against.

Historical entries in `../sdata/doc/adrs.md` relevant to this crate, current as
of 2026-07-24 (sdata's series continues to grow — check its own index table
for anything numbered past ADR-049 before assuming this list is complete):

- **ADR-039** — extraction of sdata-core as a separate Alire crate
- **ADR-040** — sdata-core deliberately holds no lexer / AST / parser (closed
  Ada enums can't be shared across applications)
- **ADR-041** — auto-detection of subscripted columns at USE time
- **ADR-042** — `Execute_OUTPUT_Table` as a parallel entry point for the
  data-vandal-style "OUTPUT writes the dataset" semantics
- **ADR-043** — per-application version constants (sdata-core's version is
  independent of sdata's)
- **ADR-045** — promoting the reserved-keyword USE warning into sdata-core
  (`Commands.Warn_Reserved_Columns`), keeping per-consumer keyword lists
- **ADR-046** — `Execute_AGGREGATE` design (active-BY grouping, build-and-swap,
  aggregate metadata side-table) — cited directly in `commands.ads`/`.adb`
- **ADR-047** — `Execute_TRANSPOSE` design (type-uniformity, union-of-IDs,
  max-K padding, output-collision rules) — cited directly in
  `commands.ads`/`.adb`
- **ADR-048** — `Execute_STATS` design (transposed-AGGREGATE layout,
  shared group-scan helper)

Use the ADRs in *this* directory for decisions this crate's own contributors
made about its internal structure (e.g. the `Table` decomposition, ADR-0007).
Use sdata's series above for decisions about this crate's public command
surface that were made from a session rooted in sdata — which, given both
consumers' `CLAUDE.md` files correctly instruct editing this crate's `src/`
directly, is common, not exceptional.

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
| [ADR-0008](ADR-0008-defer-commands-namespacing.md) | Defer SData_Core.Commands sub-namespacing; record trigger conditions | Accepted | 2026-07-24 |
| [ADR-0009](ADR-0009-cross-repo-session-tracking.md) | SSD tracking follows the crate, not the session's working directory | Accepted | 2026-07-24 |

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
