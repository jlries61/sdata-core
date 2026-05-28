---
id: ADR-0004
title: Commands package is the sole write surface for Config.Runtime
status: Accepted
date: 2026-05-26
related:
  - src/sdata_core-commands.ads
  - src/sdata_core-config-runtime.ads
  - .ssd/milestones/2026-05-22-post-extraction-baseline/skeptic-before.md
  - https://github.com/jlries61/sdata-core/pull/5
  - https://github.com/jlries61/sdata/pull/8
  - https://github.com/jlries61/sdata-core/pull/8
---

# ADR-0004: Commands package is the sole write surface for Config.Runtime

## Status

Accepted. Implementation in progress (see "Status of work" below).

## Context

The post-extraction baseline audit (2026-05-22) identified that
`SData_Core.Commands` covered approximately 70% of the actual command
space; the remaining 30% (`REPEAT`, the `OPTIONS` family, `NEW`, error
recording) was implemented by consumers writing directly to public
mutable fields of `SData_Core.Config.Runtime`. The audit's consumer-side
inventory found 14+ such direct-mutation sites in sdata across three
files, including four nearly-identical `Last_Error_Code := 1` blocks
that screamed for a `Runtime.Record_Error` helper that did not exist.

This pattern was the root cause of five distinct audit findings:

- **Fowler R1** — *Inappropriate Intimacy* between consumer and library
- **Uncle Bob U2** — dependency-direction inversion (policy reaches into
  details)
- **Evans E2** — anemic Runtime, the OPTIONS command's semantics split
  across crates
- **Feathers F4** — Runtime ownership protocol undocumented; consumers
  have to know which fields they own
- **Jobs J1** — Execute_* parameter explosion driven in part by Runtime
  not being trusted to hold defaults safely

A coherent fix requires two things: a complete public surface for the
operations consumers need, and privatization of the Runtime fields so
consumers cannot bypass that surface.

## Decision

`SData_Core.Commands.Execute_*` is the **public write surface** for every
`SData_Core.Config.Runtime` field. Consumers do not write to Runtime
fields directly. The Runtime fields themselves are migrated to a
private state with read-only accessor functions of identical names and
return types.

The decision drives a four-step implementation chain. As of the date of
this ADR, steps 1–2 have shipped; steps 3–4 are in progress:

| Step | What | PR(s) | Status |
|---|---|---|---|
| 1 | Extend `Execute_*` to cover REPEAT, NEW, OPTIONS (7 variants), Record_Error | sdata-core #5 | shipped 2026-05-26 |
| 2 | Migrate sdata's 14+ direct-mutation sites to call the new procedures | sdata #8 | shipped 2026-05-26 |
| 3 | Add `Runtime.Clear_Select_Filter` to encapsulate the one read-by-reference Runtime field; migrate sdata's `Free_Expression` call site | sdata-core #8, sdata #9 | in progress |
| 4 | Privatize the Runtime fields themselves: variables → read-only accessor functions; consumer reads continue to work via Ada parameterless-function-call syntax | sdata-core (pending) | not yet started |

### Why the multi-step chain rather than a single PR

The CI guard (`.github/workflows/consumer-tests.yml`, see ADR-0002)
clones a pinned sdata release tag and runs `make check` against the
sdata-core PR under test. Privatizing Runtime in a single PR would
break the pinned sdata tag (it still uses the old direct-write pattern)
and the CI guard would refuse to merge. The chain serialises the work
so that each step is independently verifiable, sdata can cut new
release tags between steps, and the CI pin can move forward in lockstep
with the actual privatization.

## Consequences

**Positive**

- `Config.Runtime`'s field shape becomes a private implementation
  detail. Future internal restructuring (e.g., adding sub-fields,
  changing storage representation, introducing transactional updates)
  no longer requires a consumer-side coordinated change.
- The Commands package is now consistent: every command on sdata's
  surface has a corresponding `Execute_*` procedure.
- `Execute_OPTIONS_*` procedures get a natural home for validation
  (see ADR-0005).
- Audit Findings R1, U2, E2, F4, and J1 close together when the chain
  completes.

**Negative**

- The Execute_* surface grew by ~10 procedures in one PR (#5). That is
  a meaningful API expansion. Mitigation: each new procedure is a thin
  wrapper around a single field write or validation step; they read
  identically.
- Until step 4 ships, the Runtime fields are still public-mutable, so
  the *intent* is enforced by convention. The CI guard catches
  consumer-side regressions; nothing in core prevents a new consumer
  from writing fields directly during the transition.

**Neutral**

- data-vandal had zero direct Runtime writes and is unaffected by the
  chain. The audit subagent verified this; it was re-verified before
  PR #8 in sdata was opened.

## Related

- ADR-0002 — the CI guard whose pinning strategy makes the multi-step
  chain safe.
- ADR-0005 — the validation policy adopted for the new
  `Execute_OPTIONS_*` procedures.
- The skeptic-before.md "Hook for /code-reviewer" table specifies that
  future PRs adding new Runtime fields must also add a corresponding
  `Execute_*` procedure (or use one of the existing ones). The Hook
  table is meant to be consumed by `code-reviewer` on every PR
  touching Runtime.
