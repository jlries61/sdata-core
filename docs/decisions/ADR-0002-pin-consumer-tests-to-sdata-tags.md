---
id: ADR-0002
title: Pin consumer-tests CI to sdata release tags
status: Accepted
date: 2026-05-26
related:
  - .github/workflows/consumer-tests.yml
  - https://github.com/jlries61/sdata-core/pull/1
  - https://github.com/jlries61/sdata-core/pull/7
---

# ADR-0002: Pin consumer-tests CI to sdata release tags

## Status

Accepted.

## Context

`.github/workflows/consumer-tests.yml` runs sdata's `make check` against the
sdata-core checkout under test. It needs to clone sdata as a sibling.
There were three plausible pinning strategies:

1. **Track `main`** — `ref: main` in the workflow.
   *Pro:* every commit on sdata's main is exercised.
   *Con:* a broken sdata main fails this workflow for reasons unrelated
   to the sdata-core PR under test.
2. **Pin to a commit SHA** — `ref: <SHA>` in the workflow, bumped manually.
   *Pro:* exact reproducibility; tests against a known-good state.
   *Con:* bumps are ad-hoc; SHA names carry no semantics; not obvious
   when to bump.
3. **Pin to a release tag** — `ref: v0.8.1` in the workflow, bumped on each
   sdata release.
   *Pro:* bumps are tied to deliberate releases; reads more like a
   "supported version" declaration; reduces bump churn.
   *Con:* commits between releases aren't exercised by sdata-core CI
   (only sdata's own CI catches those).

The initial PR #1 landed with a SHA pin (`e93f77b…`, sdata's `origin/main`
at PR-open time). Copilot review of PR #1 raised the tag-vs-SHA question;
follow-up commit `ccc708c` switched to `ref: v0.8.0`. The 10 commits
between `v0.8.0` and `e93f77b` at that point were all packaging
(`build:` / `docs:` / `ci:`) with no interpreter code, so the tag pin
caught the same regressions with less maintenance noise.

## Decision

`.github/workflows/consumer-tests.yml` pins the sdata checkout to a sdata
**release tag** (currently `v0.8.1`). The pin is bumped manually on each
sdata release, per the procedure documented in
`CLAUDE.md § "Build & Test" → "CI scope"`:

```bash
git -C ../sdata tag --sort=-creatordate | head -1   # latest tag
# Edit .github/workflows/consumer-tests.yml; replace `ref: vX.Y.Z` with the new tag.
# Commit as `ci(consumer-tests): bump sdata pin to vX.Y.Z`.
```

This implicitly accepts that sdata-core CI does **not** continuously test
against sdata's `main`. sdata's own CI is responsible for catching
regressions in its `main` between releases.

## Consequences

**Positive**

- Bumps are semantic ("we're now supporting sdata v0.8.1") rather than
  opaque ("we're now on SHA `abc1234`").
- Bump cadence matches release cadence — typically lower-frequency than
  every-commit churn.
- A broken sdata `main` doesn't surface as a sdata-core CI failure.
- The CLAUDE.md procedure is one trivial `sed` away from being
  scriptable.

**Negative**

- Inter-release sdata commits are not exercised by sdata-core CI.
  Mitigation: sdata's own CI checks out sdata-core@main and runs sdata's
  `make check` against it; that's the reverse direction. The same
  commits get exercised, just by a different workflow.
- Bumps are a manual step. If a sdata release lands and the maintainer
  forgets to bump, sdata-core CI falls behind the latest sdata. Not
  silent — `git -C ../sdata rev-parse origin/main` quickly reveals it.

**Neutral**

- A bumped pin can be backed out with a single revert if the new tag
  turns out to fail.

## Related

- ADR-0003 — data-vandal is deliberately excluded from this workflow.
- PR #1 — original consumer-tests workflow (SHA pin).
- PR #7 — first scheduled bump (v0.8.0 → v0.8.1) following sdata's release.
