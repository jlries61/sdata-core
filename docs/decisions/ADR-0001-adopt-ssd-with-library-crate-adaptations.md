---
id: ADR-0001
title: Adopt SSD methodology with library-crate adaptations
status: Accepted
date: 2026-05-22
related:
  - .ssd/init-log.md
  - .ssd/milestones/2026-05-22-post-extraction-baseline/skeptic-before.md
---

# ADR-0001: Adopt SSD methodology with library-crate adaptations

## Status

Accepted.

## Context

sdata-core was extracted from sdata in mid-2026 (sdata-side ADR-039). The
crate had no internal methodology — no committed CI gate, no audit cadence,
no defined relationship between consumer changes and core changes. The
risk profile flagged by the extraction work was that any breaking change
to `SData_Core.Commands.Execute_*`, `SData_Core.Config.Runtime`, or
`SData_Core.Evaluator.Expression` would silently regress one or both
consumers (sdata, data-vandal) without any automated signal.

The Shippable States Development (SSD) methodology offered a structured
answer: per-milestone audits via `codebase-skeptic`, gated PRs via
`code-reviewer`, and a `.ssd/` working directory of durable session state.
But SSD's defaults assume a deployable: tests live in the project, deploys
go to a distribution channel, feature flags gate risky changes. None of
those map cleanly to a library crate that publishes only an Alire archive.

## Decision

Adopt SSD as the methodology for sdata-core, with the following explicit
adaptations recorded in `.ssd/project.yml`:

- `stack.platform: headless` — library archive only; no executable, no
  runtime to deploy.
- `distribution.channel: alire-community-index (deferred)` — currently
  consumed via Alire path pin by `sdata` and `data-vandal`; eventual
  Alire community index publication is acknowledged but unscheduled.
- `test_command` invokes the consumer test suites
  (`cd ../sdata && make check && cd ../data-vandal && make check`)
  rather than an in-crate suite. The crate's stability contract per
  CLAUDE.md § "Public API — Stability Contract" makes the consumer
  suites the de facto gate. (See also ADR-0003 for the data-vandal
  exclusion from automated CI.)
- `feature_flag_marker: ""` — flags don't gate API-shape changes. The
  public API stability contract serves the equivalent role.
- Walking Skeleton (`/ssd start`) is skipped at adoption time because
  the crate is mid-life with two live consumers, not greenfield.

The SSD orchestrator is invoked via `/ssd` for milestones, `/ssd feature`
for per-PR work, and `/ssd gate` for the shippable-state check.

## Consequences

**Positive**

- Audits land at a known cadence with a defined output format
  (`.ssd/milestones/<topic>/skeptic-before.md` + `skeptic-after.md`).
- Per-feature briefs (`.ssd/features/<slug>/00-brief.md`) document
  rationale next to the code without polluting committed history.
- Session continuity across days is preserved via `current.yml` +
  `current.notes.yml`, so a multi-step audit chain doesn't need to be
  re-explained at each resumption.
- Cross-repo work (e.g., sdata-side migrations) is tracked under the
  top-level `archived_cross_repo_work` key in `current.notes.yml` (corrected
  2026-07-24 — this originally said `current.notes.yml.cross_repo_work`,
  which was never the actual key in use) so the audit chain doesn't
  forget about it.

**Negative**

- The `test_command` references sibling repos (`../sdata`, `../data-vandal`)
  that only exist on the maintainer's machine and in CI environments
  prepared specifically for this layout. It will not work in a
  random CI environment without those siblings present.
- Some SSD concepts (Walking Skeleton, flag rollout, deploy
  readiness checks) are inert for this crate. The orchestrator is
  aware of these via the project.yml adaptations and skips them.

**Neutral**

- `docs/decisions/`, `docs/runbooks/`, and `docs/architecture/` exist as
  committed scaffolding even when sparse. Empty directories are not
  expensive.

## Related

- `.ssd/init-log.md` — full record of the first init pass on 2026-05-22.
- sdata-side ADR-039 — original extraction rationale, including the
  stability contract that this ADR's `test_command` choice operationalises.
