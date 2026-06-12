---
id: ADR-0007
title: "Decompose SData_Core.Table behind an unchanged facade (Columns + Backing_Store + Sorting + Grouping)"
status: Accepted
date: 2026-06-12
related:
  - src/sdata_core-table.ads
  - src/sdata_core-table.adb
  - docs/specs/2026-06-12-table-decomposition-design.md
  - ADR-0004
---

# ADR-0007: Decompose SData_Core.Table behind an unchanged facade

## Status

Accepted (design). Implementation is staged across milestones M1–M5 (see the
design spec); this ADR records the decision, not its completion.

## Context

`SData_Core.Table` is a god-package: `table.adb` ~1,269 LOC owning at least
seven responsibilities (spill/backing-store, sort, schema/columns, values,
output table, BY-group, filter map) over one pile of package-level mutable
state. It is the audit's last open structural item (Uncle Bob **U1-after**).

The audit's **J1-after** finding — four/five coexisting column-name
representations (padded `String(1..Max_Name_Len)` in `Column.Name` and
`Sort_Criteria`, bare `String` map keys, `Unbounded_String` in `Column_Order`)
— was scoped on 2026-06-12 and **folded into this work** rather than done
standalone, because the decomposition reshapes `Column` / `Column_Maps` /
`Column_Order` anyway and doing the name unification separately would be
duplicated effort.

Two constraints bound the design:

- **`SData_Core.Table` is consumed directly** by `sdata` and `data-vandal` (it
  is a public package, not only reached through `Commands`). In particular the
  `Column_Type` enumeration *literals* `SData_Core.Table.Col_Numeric` /
  `Col_Integer` / `Col_String` are referenced at 16 sites, and the type at 23.
- The public name-bearing types `Sort_Criteria` (hand-built by `sdata` at
  `execute_declarative.adb`) and `Table.Name_Vectors` (via
  `Commands.Execute_ARRAY`) are also consumer-facing.

## Decision

Decompose **internal-only**, behind an unchanged public facade. No consumer
source changes; no version bump.

1. **`SData_Core.Columns`** (new, foundational, independent) holds the data
   vocabulary: `Column_Type` (relocated here), a new private `Column_Name`
   type, `Value_Vectors`, the `Column` record, and `Column_Maps`.

2. **`SData_Core.Backing_Store`** (new, independent; `with Columns`) is a
   `Backing_Store` object type owning `{DB handle, Temp_Path, Is_Active,
   segment read-cache}`, with `Initialize` / `Spill (T, Name, Start)` / `Fetch`
   / `Path` / `Clear_Cache` / `Finalize` taking the column map + context as
   parameters. Because it does not `with` `Table`, it **cannot** see Table's
   globals — the encapsulation is compiler-enforced. `SData_Core.Table` holds
   one instance and delegates. A single instance is correct: today's one shared
   `Store` (one temp DB, tables `"data"` and `"output_data"`) and the
   input-only segment read cache already model this.

3. **`SData_Core.Sorting`** and **`SData_Core.Grouping`** (new; later
   milestones) take the `Sort` (157 LOC) and BY-group clusters out of the
   facade. Unlike `Backing_Store` these have Table-ward dependencies —
   `Sorting` needs the public `Sort_Criteria` / `Sort_Direction`, and
   `Grouping`'s `In_Same_Group` reads cell values. The design spec (§4.4)
   resolves both without a `with Table` cycle: relocate `Sort_Criteria` /
   `Sort_Direction` to `Columns` with the same re-export shim, and have
   `Grouping` read cells via `Columns.Column_Maps` directly. The fallback, if
   either proves awkward at the milestone, is a private child package (trades
   compiler-enforced isolation for simplicity); the facade and public API are
   unaffected either way.

4. **`SData_Core.Table`** remains the facade with its public API byte-for-byte
   intact. `Column_Type` is re-exported so no consumer breaks:

   ```ada
   subtype Column_Type is SData_Core.Columns.Column_Type;
   function Col_Numeric return Column_Type renames SData_Core.Columns.Col_Numeric;
   function Col_Integer return Column_Type renames SData_Core.Columns.Col_Integer;
   function Col_String  return Column_Type renames SData_Core.Columns.Col_String;
   ```

   Enumeration literals are parameterless functions, so they rename cleanly; a
   `subtype` carries the base type's operations, so `use type
   SData_Core.Table.Column_Type;` and the literal comparisons keep compiling
   unchanged. `Sort_Criteria`, `Sort_Direction`, `Index_Array`, `Name_Vectors`,
   and `Type_Mismatch_Error` stay in `Table` as-is.

5. **`Column_Name`** (private, `Unbounded_String`-backed, upper-casing baked
   into its one constructor `To_Column_Name`) becomes the single internal
   representation for `Column.Name`, the `Column_Maps` key, and
   `Column_Order` / `Output_Column_Order`. This closes the *internal* half of
   J1. The public API continues to take and return `String`; the facade
   converts at the boundary.

The work is staged M1 (Columns relocate) → M2 (`Column_Name`) → M3
(`Backing_Store`) → M4 (`Sorting`) → M5 (`Grouping`), each behavior-preserving
and gated by the in-crate drivers plus both consumer suites. See
`docs/specs/2026-06-12-table-decomposition-design.md` for the implementation
detail.

## Consequences

**Positive**

- `table.adb` shrinks to a facade over cohesive, independently-readable units;
  the spill kernel and sort become testable in isolation.
- The `Backing_Store` seam Uncle Bob identified is realized with
  compiler-enforced encapsulation, not code merely relocated over shared
  globals.
- J1's internal representation sprawl collapses to one `Column_Name` type with
  a single upper-casing chokepoint — the subtlest column-name bug class is
  designed out, not just case-normalized.
- Zero consumer churn and no version bump: the facade and the `Column_Type`
  re-export keep the public contract identical.

**Negative**

- The `Column_Type` re-export shim is boilerplate that must stay in lockstep
  with `Columns.Column_Type` (three literal renames + one subtype). The M1 gate
  ("both consumers build untouched") guards it.
- The decomposition is multi-milestone; partial completion leaves the codebase
  in an intermediate shape (still correct, still green) for a while.

**Neutral**

- No observable behavior or performance change at any milestone — structure
  only. K5-after (single-segment cache → LRU) is *enabled* as a future
  localized change by the `Backing_Store` extraction but is not implemented.

## Non-goals

- The **public** half of J1: `Sort_Criteria.Name+Len` and
  `Table.Name_Vectors`. Unifying those onto `Column_Name` is a public break
  needing its own ADR, coordinated consumer edits, and a version bump. It
  remains a documented known-gap.
- K5-after (segment-cache LRU) and W5-after (BY-group cursor-cache reuse, an
  optional M5 sub-step gated on adding no risk).

## Related

- ADR-0004 — `Commands` as the command-semantics surface; `Table` is the data
  layer it drives. This decomposition does not change that boundary.
- `docs/specs/2026-06-12-table-decomposition-design.md` — the milestone-level
  implementation design this ADR ratifies.
