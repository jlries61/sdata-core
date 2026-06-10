# sdata-core in-crate tests

A small set of standalone Ada drivers covering the pure-function subset
of sdata-core's public API.

## What's covered

| Driver | Surface |
|---|---|
| `values_tests.adb` | `Is_Inf`, `To_String`, `Is_True`, `"="`, `"<"` across every `Value_Kind` permutation |
| `parse_expression_tests.adb` | `Parse_Expression` round-trips for each `Expression_Kind` plus malformed inputs |
| `call_function_tests.adb` | `Call_Function` against one representative from each registered family (Numeric, String, Aggregate, Misc) plus unknown-name handling |
| `statistics_tests.adb` | `SData_Core.Statistics` — all 14 distributions (PDF/PMF, CDF, IDF, RNG): canonical reference values, CDF boundaries + monotonicity, IDF round-trips, symmetry, PDF non-negativity, seeded-RNG support membership |

Each driver is a plain Ada main with inline assertions — no framework. A
failing assertion prints `FAIL: <name>` and the driver exits non-zero.

## What's NOT covered

Anything that requires interpreter state (`Variables`, `Table`, `Config.Runtime`)
or external I/O (`File_IO`, `IO`, `System`, `Signals`). Those are integration
concerns that legitimately belong in the consumer test suites
(`sdata make check`, `data-vandal make check`).

## Running

```sh
tests/run-tests.sh
```

Builds and runs all four drivers; exits 0 if every assertion in every
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
