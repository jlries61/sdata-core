# sdata-core in-crate tests

A small set of standalone Ada drivers covering the pure-function subset
of sdata-core's public API, plus the in-process Runtime-stateful command
seam that the `Config.Runtime` privatization made testable in isolation.

## What's covered

| Driver | Surface |
|---|---|
| `values_tests.adb` | `Is_Inf`, `To_String`, `Is_True`, `"="`, `"<"` across every `Value_Kind` permutation |
| `parse_expression_tests.adb` | `Parse_Expression` round-trips for each `Expression_Kind` plus malformed inputs |
| `call_function_tests.adb` | `Call_Function` against one representative from each registered family (Numeric, String, Aggregate, Misc) plus unknown-name handling |
| `statistics_tests.adb` | `SData_Core.Statistics` — all 14 distributions (PDF/PMF, CDF, IDF, RNG): canonical reference values, CDF boundaries + monotonicity, IDF round-trips, symmetry, PDF non-negativity, seeded-RNG support membership |
| `commands_tests.adb` | `SData_Core.Commands` Runtime-stateful surface — OPTIONS setters (incl. length-validation raises), `Execute_REPEAT`, `Execute_Record_Error`, `Execute_NEW` reset, and `Resolve_Use_Defaults` fallback/passthrough — each driven via `Execute_*` and read back through the `Config.Runtime` accessors |

Each driver is a plain Ada main with inline assertions — no framework. A
failing assertion prints `FAIL: <name>` and the driver exits non-zero.

## What's NOT covered

The `Variables` and `Table` data structures, and external I/O (`File_IO`,
`IO`, `System`, `Signals`). The `Config.Runtime` *command* seam is now
covered (above) — but the `Execute_*` paths that load or write data
(`Execute_USE`, `Execute_SAVE`, the data step) are not, since they require a
populated table and the filesystem. Those remain integration concerns that
belong in the consumer test suites (`sdata make check`,
`data-vandal make check`).

## Running

```sh
tests/run-tests.sh
```

Builds and runs all five drivers; exits 0 if every assertion in every
driver passes.

## Rationale

Per audit Finding Beck B1 from
`.ssd/milestones/2026-05-22-post-extraction-baseline/skeptic-before.md`,
sdata-core has testable pure seams that previously relied on the consumer
suites for verification. A full `alr build` of sdata-core takes minutes
on a cold cache; bouncing through both consumer suites for a one-line
change to `Values` was disproportionate. This driver provides a
seconds-scale sanity gate for that subset.

The consumer suites remain the gate for everything that depends on
interpreter state.
