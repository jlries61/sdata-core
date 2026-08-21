---
id: ADR-0013
title: "New Table.Partition_By_Key primitive replaces adjacency-based grouping; BY stops sorting the table"
status: Accepted
date: 2026-08-19
related:
  - ../../../sdata/doc/adrs.md
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md
  - ../../../sdata/.ssd/features/pd1-by-sort-scoping/00-brief.md
  - ../../../data-vandal/src/data_vandal-execute_vandalize.adb
---

# ADR-0013: New `Table.Partition_By_Key` primitive replaces adjacency-based grouping; `BY` stops sorting the table

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PD-1**, `part-d-file-io-execution-model.md`) found that `BY`
physically sorts the table (`sdata-interpreter-execute_declarative.adb`'s `Stmt_BY` handler calls
`SData_Core.Table.Sort` unconditionally) and, as a direct consequence, merges non-adjacent
same-key rows into one block — contradicting design.md §5.2's explicit "blocks need not be sorted"
/ "non-consecutive blocks stay separate" rules, and contradicting the `BY` command's own §7.1 row,
which repeats the same claim almost verbatim.

The audit assumed the *code's* sorting behavior was the intended one and recommended a doc-only
fix. That assumption was wrong: the project owner confirmed the actual intended design, which also
matches real SAS-family `BY`-statement semantics (SAS's `BY` assumes pre-sorted input and does not
itself re-sort; non-adjacent runs of the same key are separate BY-groups) —

- Ordinary `RUN` group navigation (`BOG`/`EOG`/`LAG`/`NEXT`/`RECNO`) must take BY-groups **as they
  come**, with no forced sort.
- `AGGREGATE`, `TRANSPOSE`, `STATS`, and `TABLES` legitimately need every same-key row grouped
  together regardless of original adjacency — a per-key summary/reshape/cross-tab cannot
  reasonably be split across non-adjacent occurrences of the same key.

Tracing the actual implementation (not just the audit's summary) found: there is exactly **one**
sort trigger (`Stmt_BY`'s `Table.Sort` call, sdata), and **two** consumers that both rely on it via
the same underlying mechanism —

- `sdata-interpreter.adb`'s `Group_Flags` (ordinary `RUN` navigation): compares only the *current
  logical row's immediate physical neighbors* via `Table.In_Same_Group` — genuinely adjacency-only,
  no merging of non-adjacent runs. This already implements §5.2's exact semantics; it only produces
  the wrong (merged) result today because the table happens to already be sorted by the time it
  runs. **No change needed here** once `BY` stops sorting.
- `sdata_core-commands.adb`'s `Group_Boundaries` (shared by `AGGREGATE`, `STATS`, `TRANSPOSE`, and
  sdata's `TABLES`): partitions `Logical_Row_Count` into runs via the *same* adjacency check
  (`In_Same_Group` on consecutive logical rows). This is the one that's actually wrong for these
  four commands' own requirements once `BY` stops sorting — it needs every same-key row together,
  and adjacency alone can no longer guarantee that.

`AGGREGATE`, `TRANSPOSE`, and `STATS` all build-and-swap a fresh output table
(`Initialize_Output_Table` → `Add_Output_*` → `Commit_Output_Table`), so an internal
pre-sort-then-scan would have no effect visible after the command completes. `TABLES`
(`sdata-interpreter-execute_tables.adb`) does not — it is a pure read/display command, confirmed by
direct inspection (no `Table.Sort`, no output-table replacement anywhere in the file). Giving
`TABLES` its own internal `Table.Sort` call would permanently reorder the user's live table as a
side effect of a command that looks read-only — exactly the kind of silent surprise this fix exists
to remove, just relocated rather than eliminated.

**A third, independent consumer surfaced during design, in the private `data-vandal` sibling
repo**: `VANDALIZE ... /BY=`'s `Compute_Groups` (`data_vandal-execute_vandalize.adb`) assigns
per-row group IDs via the identical adjacency-only `In_Same_Group` pattern as `Group_Flags` — its
own source comment says outright, "Requires the table is sorted by BY vars (same assumption as the
BY statement)." This is not a hypothetical risk; it is the same defect class PD-1 describes,
independently reachable, in a repo this decision did not originally plan to touch. Folded into
scope (user's explicit direction) rather than left as a follow-up, since shipping the `BY` sort
removal without it would introduce a real regression in `data-vandal`, not merely leave a
pre-existing gap unaddressed.

`Compute_Groups` cannot simply call `Group_Boundaries` directly, though: `Group_Boundaries`
operates over `Logical_Row_Count` (respects the active `SELECT` filter, via `Rebuild_Filter_Map`),
while `Compute_Groups` operates over raw `SData_Core.Table.Row_Count` (confirmed by reading both —
`Compute_Groups`'s `N : constant Natural := SData_Core.Table.Row_Count`, unfiltered). Confirmed
empirically that this divergence is real and current, not merely theoretical: `SELECT A > 1` then
`VANDALIZE A /MISS=1.0` reports `"VANDALIZE complete. 6 records processed"` against a 6-row table
where `SELECT` had filtered 5 rows into scope — `VANDALIZE` does not honor `SELECT` at all today
(confirmed in source too: `execute_vandalize.adb` has no reference to `Stmt_SELECT`/
`Execute_SELECT`/any filter machinery anywhere in the file; `data-vandal`'s README bullet "Honors
an active SELECT" describes `DISPLAY`, not `VANDALIZE` — an earlier draft of this ADR mis-attributed
that claim). Regardless: `Compute_Groups` keeps its own existing (unfiltered) row scope rather than
adopting `Group_Boundaries`'s (filtered) one, so this decision does not depend on, alter, or need to
correct that pre-existing, unrelated `SELECT` non-interaction — it is simply preserved as-is, same
as everything else about `Compute_Groups`'s scope this ADR doesn't touch.

## Decision

1. **`Stmt_BY` stops sorting.** It still validates the BY variable names and registers them via
   `Table.Add_By_Var` (needed for `In_Same_Group`'s key comparison) — but the `Table.Sort (Crit)`
   call is removed. `BY` becomes purely declarative in the sense §5.2 already describes: it names
   the grouping key: it does not touch row order.

2. **The actual partitioning algorithm is extracted as a new, lower-level, filter-agnostic public
   primitive** — `SData_Core.Table.Partition_By_Key (Physical_Rows : Row_Index_Vectors.Vector)
   return Row_Group_Vectors.Vector` (exact package/name is coder's call; `Table` is the natural
   home since it already owns `In_Same_Group`, `Sort`, and the By-var registry) — rather than
   baking the hash-partition logic directly into `Group_Boundaries`'s body. It takes an arbitrary
   caller-supplied list of physical row indices (not "all rows," not "filtered rows" — whatever the
   caller decides is in scope) and returns them bucketed by the active BY variables' key values,
   sorted group-list-first by key (see below), with no assumption about how the caller selected
   those indices:
   - Single pass over the supplied physical row indices, computing a canonical composite key from
     the current values of the active BY variables for each row (composite key type, not
     delimiter-joined string — see Consequences).
   - Bucket into a hash map keyed by that composite key, preserving each bucket's internal row
     order (insertion order = the order the caller's index list presented them in).
   - Sort the resulting *list of groups* (not the rows within them, not any live table) by BY-key
     value, using the same comparison `Table.Sort`'s criteria already express.
   - Never touches table row order, never consults `SELECT`/filtering — filtering is entirely the
     caller's responsibility, expressed by which physical indices it passes in.

3. **`Group_Boundaries`** (`sdata_core-commands.adb`, shared by `AGGREGATE`/`STATS`/`TRANSPOSE`/
   sdata's `TABLES`) becomes a thin wrapper: `Rebuild_Filter_Map` (unchanged), collect
   `Logical_To_Physical (L)` for `L in 1 .. Logical_Row_Count` into a `Row_Index_Vectors.Vector`,
   call `Partition_By_Key` with it. Return type and all four call sites unchanged — this preserves
   `SELECT`-respecting behavior exactly as today, just via the new shared primitive instead of an
   adjacency scan.

4. **`data-vandal`'s `Compute_Groups`** replaces its own hand-rolled `In_Same_Group` adjacency loop
   with a call to the same `Partition_By_Key`, passing physical indices `1 .. N` (`N =
   SData_Core.Table.Row_Count`, unfiltered — identical to its current scope, so `SELECT`-interaction
   behavior is unchanged, not silently altered), then converts the returned
   `Row_Group_Vectors.Vector` into its own per-row `Group_Array` numbering (for `G in
   Result'Range`, for each physical index in `Result (G)`, `Groups (Index) := G`). data-vandal
   depends on sdata-core already; no new dependency.

5. This resolves the `TABLES` question the brief posed without a `TABLES`-specific special case,
   and resolves the `data-vandal` regression surfaced during design without a second, independent
   fix: both get correct grouping through the same shared, non-mutating `Partition_By_Key`
   primitive. No internal sort, no live-table side effect, ever, for any of the four sdata-core
   commands or `VANDALIZE`.

## Rationale

- **One shared primitive, not five accommodations.** Extracting `Partition_By_Key` once (reused by
  `Group_Boundaries`'s four call sites *and* `data-vandal`'s `Compute_Groups` unchanged in their own
  filtering semantics) is smaller in total surface area and risk than adding an internal
  `Table.Sort` to three sdata-core commands, inventing a separate non-mutating mechanism for
  `TABLES`, and a *sixth*, independent fix for `data-vandal` — and it removes both the `TABLES` and
  `data-vandal` special cases entirely rather than resolving each awkwardly and separately.
- **Correctness and today's observable behavior both preserved, in both repos.** Hash-partitioning
  fixes the actual grouping defect (works regardless of row order); sorting only the resulting group
  list (not the table) preserves existing output row order for `AGGREGATE`/`STATS`/`TRANSPOSE`/
  `TABLES`; passing each caller's own existing row-index scope (filtered for `Group_Boundaries`,
  unfiltered for `Compute_Groups`) into the *same* primitive preserves each one's existing
  `SELECT`-interaction behavior exactly, rather than silently unifying it.
- **`Group_Flags` needed no change** — confirmed by reading it, not assumed. Its adjacency-only
  comparison already implements the documented, intended `RUN` semantics; it was only ever "wrong"
  because of `BY`'s side effect on the data it compared, not because of anything in `Group_Flags`
  itself.

## Consequences

**Positive**

- Closes PD-1 for real (behavior, not just documentation) while keeping design.md's own AGGREGATE
  row's implicit output-order guarantee true.
- `BY` becomes non-mutating, matching §5.2 and its own §7.1 row exactly, with zero known residual
  contradiction.
- `TABLES`, `data-vandal`'s `VANDALIZE ... /BY=` (and any future BY-consuming command in either
  repo) inherit correct, side-effect-free grouping for free by calling `Partition_By_Key`, rather
  than each needing its own case-by-case reasoning about sort-safety — closes a regression this
  workstream would otherwise have introduced into `data-vandal`, not just left a pre-existing gap
  unaddressed there.

**Negative**

- `Group_Boundaries`'s new hash-partition-then-sort-groups implementation is more code than the
  adjacency scan it replaces, and introduces a composite-key construction concern that didn't exist
  before. Per-column type ambiguity is *not* a real risk (a given BY-variable column has one fixed
  declared type across every row, so an integer `1` in column A can never be confused with a
  character `"1"` in column A — there is nothing to disambiguate within a single column). The real
  risk is **delimiter collision across multiple BY variables**: naively joining
  `SData_Core.Values.To_String` output for each BY column with a fixed separator is ambiguous when
  a character BY-variable's own value can contain that separator (`A="X|Y", B="Z"` and `A="X",
  B="Y|Z"` both flatten to `"X|Y|Z"` under a plain `"|"`-joined scheme). Avoid by not flattening to
  a single string at all — use a composite key type (e.g. a `Name_Vectors.Vector` of the
  per-column formatted values, or a small record of `Value`s, with a matching custom `Hash`
  function for the hashed map) rather than string concatenation.
- Performance: a hash-partition + group-list sort is `O(n)` partition + `O(g log g)` group sort
  (g = distinct groups) versus the previous `O(n)` adjacency scan over an already-sorted table
  (the sort itself was `O(n log n)`, paid once by `BY`). Net complexity is comparable or better
  (no `O(n log n)` full-row sort at all now, only a typically-much-smaller `O(g log g)` group-list
  sort) but this needs confirming under this project's own performance conventions, not just
  asserted.
- design.md's AGGREGATE row ("Note that because BY sorts the table...") must be reworded — it
  attributes grouping to a mechanism (`BY`'s sort) that no longer exists. `TRANSPOSE`/`STATS`/
  `TABLES` rows should each gain an explicit grouping-guarantee statement rather than continuing to
  rely on an implicit, now-false "BY already sorted this" assumption, per `CLAUDE.md`'s
  user-facing-surface-sync convention.

## Alternatives Rejected

- **Give `AGGREGATE`/`TRANSPOSE`/`STATS` their own internal `Table.Sort`, and solve `TABLES`
  separately** (the brief's framing) — rejected once tracing the code showed all four already share
  one call site (`Group_Boundaries`); fixing that one shared site is strictly less code and less
  risk than three near-duplicate internal-sort additions plus a bespoke fourth mechanism.
- **Sort a private copy of the table for `TABLES` only** — rejected for the same reason: the shared
  `Group_Boundaries` fix makes this unnecessary, and a private-copy sort would still cost `O(n log
  n)` plus a full table copy, strictly worse than the chosen hash-partition approach.
- **Leave `BY`'s sort in place; make it conditional on which command runs next** — rejected as
  fundamentally the wrong shape: `BY` is declarative and doesn't know what command will consume its
  grouping next (`RUN` could be followed by an arbitrary number of ordinary deferred-statement
  cycles before an `AGGREGATE` ever runs, or never). Pushing the sort-vs-no-sort decision to the
  point where grouping is actually consumed (inside `Group_Boundaries`, vs. inside ordinary
  `Group_Flags`) is the only place the distinction can correctly be made.
- **Have `data-vandal`'s `Compute_Groups` call `Group_Boundaries` directly**, rather than extracting
  a lower-level `Partition_By_Key` both can call — rejected because `Group_Boundaries` bakes in
  `SELECT`-filtering (`Logical_Row_Count`), while `Compute_Groups` currently operates unfiltered
  (`Table.Row_Count`); forcing the direct call would either require `Compute_Groups` to fake an
  unfiltered `SELECT` state around the call (fragile, and `data-vandal` already does exactly this
  kind of save/restore dance for `By_Var` state elsewhere, which is itself flagged as failure-prone
  in its own comments) or would silently change which rows `VANDALIZE` groups under an active
  `SELECT` — an unreviewed, unrelated behavior change. A primitive parameterized on the caller's own
  row-index list sidesteps the mismatch entirely instead of forcing one side to adapt to the other.
- **Fix `data-vandal` separately, as its own follow-up issue** (mirroring #117/#118's precedent from
  the prior workstream) — rejected specifically for this finding, per explicit user direction: unlike
  #117/#118 (genuinely separate design questions the audit never touched), this one is a regression
  *this exact workstream* would introduce if shipped without it, not a pre-existing, independently-
  discovered gap — the distinction that made deferral appropriate for #117/#118 doesn't hold here.

## Related

- sdata `.ssd/audits/2026-08-13-design-vs-implementation/part-d-file-io-execution-model.md` finding
  PD-1.
- sdata `.ssd/features/pd1-by-sort-scoping/` — the workstream implementing this decision.
- design.md §5.2 "Grouping Rules", §7.1 `BY`/`AGGREGATE`/`TRANSPOSE`/`STATS`/`TABLES` rows.
