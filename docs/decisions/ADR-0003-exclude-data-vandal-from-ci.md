---
id: ADR-0003
title: Exclude data-vandal from consumer-tests CI
status: Accepted
date: 2026-05-22
related:
  - .github/workflows/consumer-tests.yml
  - https://github.com/jlries61/sdata-core/pull/1
---

# ADR-0003: Exclude data-vandal from consumer-tests CI

## Status

Accepted.

## Context

The initial design of `.github/workflows/consumer-tests.yml` had two
parallel jobs: one for sdata's `make check`, one for data-vandal's.
The intent was full closure of audit Finding F1: every consumer test
suite automatically gates every sdata-core PR.

While the PR was open, the maintainer made the `jlries61/data-vandal`
repository **private**. The previous two-job workflow then failed on
the data-vandal job because `actions/checkout@v4` could not clone a
private repository without authentication.

The technical fix for cross-repo private checkout is straightforward —
either a Personal Access Token or a deploy key, stored as a repository
secret in sdata-core. Either approach exposes a different surface, though:
the workflow runs in the **public** sdata-core repository, so every PR's
Actions log would contain:

- `data-vandal` filenames as they are compiled (`Compiling
  data_vandal-interpreter.adb…`)
- Test names as they run (`tests/vandalize_stub.cmd…`)
- Stdout from any failing test (the diff output against
  `tests/expected/*.out`)

Source code itself never appears in the logs (it stays on the ephemeral
runner), but enough structure leaks that a thoughtful reader could
reconstruct meaningful information. That partially defeats the privacy
decision behind making the repository private in the first place.

Alternatives considered:

1. **PAT / deploy key with accepted log leakage** — full F1 closure but
   permanently leaks structure.
2. **Cross-repo `workflow_dispatch`** — data-vandal's private CI runs the
   tests and posts a status check back to sdata-core's PR. Heavier setup;
   not justified at single-maintainer scale.
3. **Re-public data-vandal** — reverses the recent privacy decision.
4. **Drop the data-vandal job from the workflow** — partial F1 closure;
   data-vandal validation remains a manual gate.

## Decision

Drop the `data-vandal` job from `consumer-tests.yml`. data-vandal
validation reverts to a **manual gate** documented in
`CLAUDE.md § "Build & Test"`:

```bash
cd ~/Develop/data-vandal && make check
```

Maintainer discipline before every commit to sdata-core. The workflow
file's header comment explicitly explains the exclusion so future readers
do not assume it was an oversight.

This is **partial closure** of audit Finding F1, not full. If data-vandal
ever goes public, or if the cross-repo workflow_dispatch alternative becomes
worth the effort, the deleted job can be restored from PR #1's commit
history (specifically commit `b2c9a76` had the full two-job version).

## Consequences

**Positive**

- No new credential lifecycle (no PAT to rotate, no deploy key to manage).
- No log leakage in public sdata-core Actions.
- Workflow file remains small and reviewable.

**Negative**

- A sdata-core change that breaks **data-vandal but not sdata** is not
  automatically caught. Mitigation: per the audit's analysis, this
  pattern is unlikely in the short run — most cross-consumer regressions
  fail sdata's much larger test suite (140 tests vs 15) before they
  fail data-vandal's.
- The "did I remember to run data-vandal's make check?" cognitive load
  falls on the maintainer.

**Neutral**

- The closure status of audit Finding F1 is documented as **partial**
  in `.ssd/archive/features/consumer-test-ci-guard/05-deploy.md` so a
  future re-audit doesn't claim full closure.

## Related

- ADR-0002 — sdata pinning strategy in the same workflow.
- PR #1 — final form (sdata-only) of the consumer-tests workflow.
- The unused two-job version remains accessible at sdata-core commit
  `b2c9a76` should the privacy posture change.
