---
id: ADR-0029
title: "Amortize Add_Column's cursor-cache maintenance instead of a full rebuild on every insert"
status: Accepted
date: 2026-10-08
related:
  - ADR-0028-hashed-set-duplicate-column-check.md
  - sdata-core#156
  - ../../.ssd/features/warn-duplicate-name-perf-fix/00-brief.md
---

# ADR-0029: Amortize `Add_Column`'s cursor-cache maintenance instead of a full rebuild on every insert

## Status

Accepted.

## Context

ADR-0028 fixed `Warn_If_Duplicate_Name`'s O(n²) linear scan, the root cause filed in
sdata-core#156. Verifying that fix against a synthetic wide file (10,000 columns, piped through
`bin/sdata`) showed it was **not sufficient**: even with zero duplicate column names (so
`Warn_If_Duplicate_Name` never takes its warn branch at all), loading showed the same textbook
quadratic signature — 0.21s / 0.66s / 2.67s user time at 1,000 / 2,000 / 4,000 columns, roughly
4× per doubling.

Traced to `SData_Core.Table.Add_Column` (`src/sdata_core-table.adb`): every single column
insertion unconditionally calls `Rebuild_Column_Cache`, which clears and rebuilds the *entire*
`Column_Cursor_Cache` — one `Data_Table.Find` per existing column — from scratch. Adding N columns
one at a time therefore does `1 + 2 + ... + N` = O(N²) total cursor-cache work, independent of
`Warn_If_Duplicate_Name` and independent of whether any name collides. The existing code comment
explains the motivation: `Data_Table.Insert` on the underlying `Indefinite_Hashed_Maps.Map` can
trigger a rehash that invalidates every previously-obtained cursor, so the cache must be rebuilt
whenever that happens — but the code paid that cost on *every* insert, not just the ones that
actually rehash.

Both bottlenecks live in the same call path (each reader's per-column naming loop calls
`Warn_If_Duplicate_Name` then `Add_Column`), and both scale the same way, which is why the real
54,614-column file's multi-minute hang matches the *combination*, not either one alone.

## Decision

Detect whether `Data_Table.Insert` actually rehashed by comparing
`Ada.Containers.Indefinite_Hashed_Maps.Map'Capacity` before and after the call:

- **Capacity unchanged** (the common case, once the bucket array has grown enough): append just
  the new column's cursor to `Column_Cursor_Cache` — O(1).
- **Capacity changed** (a rehash occurred, invalidating every prior cursor): fall back to the
  existing full `Rebuild_Column_Cache` — O(current size), exactly as before.

`Capacity` is a standard `Ada.Containers.Indefinite_Hashed_Maps` operation (confirmed present in
the GNAT 15.2.1 runtime's `a-cihama.ads`) and never decreases from `Insert` alone (no shrink-on-
insert in this container), so "`Capacity` changed" is both necessary and sufficient as the rehash
signal — no new dependency, no behavioral assumption beyond what the standard container already
guarantees.

## Rationale

This is the same amortized-doubling argument that makes a growable array's `Append` O(1): across N
inserts, the bucket array only grows O(log N) times (geometric growth), and each growth's
rebuild costs O(current size) — the sum of a geometric series is O(N), not O(N log N) or O(N²).
Net: N `Add_Column` calls now cost O(N) total instead of O(N²), with the exact same correctness
guarantee the original full-rebuild-on-every-insert code had (a rehash still always triggers a
full rebuild; nothing is skipped in that case).

## Consequences

- **Easier:** loading a wide file no longer pays quadratic cursor-cache-maintenance cost on top of
  the (now also fixed, ADR-0028) quadratic duplicate-name-check cost. The two fixes together are
  what actually resolves sdata-core#156's symptom (a 54,614-column file hanging); ADR-0028 alone
  was necessary but not sufficient, confirmed by direct measurement before this fix was written.
- **Harder:** nothing new to reason about day-to-day — the invariant ("cache mirrors Column_Order
  in cursor form") is unchanged; only *how* it's kept in sync on the common path changed.
- **Gives up:** nothing. The fallback path means a rehash-heavy load pattern still costs exactly
  what it cost before (full rebuild), so there's no regression in that case — only improvement in
  the far more common no-rehash case.
- **Deliberately out of scope:** `Add_Output_Column` (same file, used by TABLES/SAVE's output-
  table construction) has the identical full-rebuild-per-insert pattern via `Rebuild_Output_Cache`.
  Output tables are built from BY-group/crossing-variable combinations and stat columns, which are
  never wide-file-scale in practice, so this is not part of the sdata-core#156 symptom and is left
  unfixed here — flagged for a future pass if an output-table use case is ever found to need it.

## Alternatives Rejected

- **Track a "dirty" flag and rebuild lazily on next read.** More moving parts (every read site
  would need a check-and-rebuild-if-dirty guard) for the same asymptotic result; the capacity-
  comparison approach gets O(N) with no new invariant for callers to maintain.
- **Switch `Column_Cursor_Cache` away from cursors to cached keys, re-`Find` on each row access.**
  Rejected — this is the exact per-row O(1)-no-hash-lookup property the cache exists to provide
  (per sdata's CLAUDE.md "PDV" section); trading it away to simplify column *loading* (a one-time,
  per-file cost) at the expense of every row access during `RUN` (the actual hot path) would be
  backwards.
