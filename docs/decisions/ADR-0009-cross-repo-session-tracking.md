---
id: ADR-0009
title: "SSD tracking follows the crate, not the session's working directory"
status: Accepted
date: 2026-07-24
related:
  - CLAUDE.md
  - ADR-0001
  - .ssd/milestones/2026-07-23-post-decomposition-baseline/
---

# ADR-0009: SSD tracking follows the crate, not the session's working directory

## Status

Accepted.

## Context

sdata-core is consumed by two sibling crates (`sdata`, `data-vandal`) via an Alire path pin, and both
consumers' own `CLAUDE.md` files correctly instruct their sessions to modify
`~/Develop/sdata-core/src/` directly when the change is to shared data-layer, evaluator, or
command-execution code — rather than duplicating it in the consumer. In practice this means the
*majority* of sessions that touch sdata-core files are rooted in `sdata` or `data-vandal`, not in
sdata-core itself, and will only ever load that other repo's `CLAUDE.md` automatically.

sdata-core has its own independent, gitignored `.ssd/current.yml` (per ADR-0001's adoption of SSD for
this crate). So does each consumer. These three trackers have **zero visibility into one another** —
nothing in any of the three `CLAUDE.md` files, before this ADR, told a consumer-rooted session that
sdata-core was SSD-tracked at all, let alone where its tracker lived or that it should be consulted.

This is not a hypothetical risk. The 2026-07-23 milestone audit
(`.ssd/milestones/2026-07-23-post-decomposition-baseline/`) discovered that sdata-core's prior
milestone had actually closed on 2026-06-15, but `.ssd/current.yml` was never updated to reflect it —
leaving the workstream open at a stale phase while 117 commits and 34 PRs landed over the following six
weeks with no SSD tracking at all. That specific instance happened within sdata-core-rooted work. The
same failure mode is at least as likely from the opposite direction going forward: as of this ADR, most
day-to-day feature work is expected to be driven from `sdata` or `data-vandal` sessions that incidentally
touch sdata-core, with no prompt anywhere to check this crate's own tracker or documentation
conventions before doing so.

## Decision

**sdata-core's `CLAUDE.md` now states explicitly that its rules bind any session touching this crate's
files, regardless of which repo the session is rooted in** — including the requirement to check and, for
non-trivial changes, update `.ssd/current.yml` in *this* crate specifically (not the originating repo's).
See CLAUDE.md's "This file binds every session touching this crate, regardless of origin" section for
the operative checklist (read this file in full; run the three-way build/test gate; check/update this
crate's `.ssd/current.yml`; follow this crate's own versioning and documentation conventions rather than
the originating repo's).

Both consumers' `CLAUDE.md` files are updated in turn to point back here with an actual directive —
"read sdata-core's `CLAUDE.md` before editing anything under it" — rather than a passive reference-list
entry, and to name the SSD-tracking requirement specifically rather than leaving it implicit in "go read
that file."

This is a documentation/instruction fix, not a tooling one: there is no automated enforcement (a
consumer-rooted session could still skip it), matching this project's general SSD posture that
"enforcement is warnings, not walls" (per the SSD methodology's own ADR-0012 in the skill's source,
referenced for context — sdata-core does not implement its own enforcement layer here).

## Consequences

**Positive**

- A consumer-rooted session editing sdata-core files now has an explicit, first-contact instruction to
  check this crate's own SSD state and documentation conventions, rather than silently applying the
  originating repo's.
- The failure mode that caused the 2026-06/07 tracking gap is named and cross-referenced from all three
  `CLAUDE.md` files, not just sdata-core's own audit history.

**Negative**

- Still relies on the session actually reading and following CLAUDE.md instructions — no mechanical
  gate (e.g., a pre-commit hook checking `.ssd/current.yml` freshness) enforces this. Adding one is
  future work if instruction-following alone proves insufficient in practice.
- Three files now need to stay in sync if this convention changes; drift between them is itself a risk
  this ADR doesn't fully close.

## Non-goals

- A unified, cross-repo SSD tracker (e.g., one shared `.ssd/` for all three crates). The three crates
  have independent release cadences, version numbers (ADR-043 in sdata's ADR series), and audit scopes;
  a shared tracker would blur those. Each crate keeps its own `.ssd/`; this ADR only ensures sessions
  know to check the *right* one for the file they're touching.
- Automated enforcement (hooks, CI checks) of SSD-tracking freshness. Deferred; see Consequences.

## Related

- ADR-0001 — original adoption of SSD for this crate, including the cross-repo `current.notes.yml`
  convention for the opposite direction (sdata-core-rooted work that requires a consumer-side change).
- `.ssd/milestones/2026-07-23-post-decomposition-baseline/` — the audit that discovered the concrete
  instance of this gap and prompted this ADR.
