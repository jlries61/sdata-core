---
id: ADR-0016
title: "--clen defaults to 256 per design.md; Table.Coerce_Value warns on truncation, matching LET/SET's existing granularity"
status: Accepted
date: 2026-08-23
related:
  - ../../../sdata/.ssd/audits/2026-08-13-design-vs-implementation/part-c-data-model-variables.md
  - ../../../sdata/.ssd/features/pc5-clen-default/00-brief.md
---

# ADR-0016: `--clen` defaults to 256 per design.md; `Table.Coerce_Value` warns on truncation

## Status

Accepted.

## Context

sdata's 2026-08-13 re-audit (finding **PC-5**, `part-c-data-model-variables.md`) found
`SData_Core.Config.Max_String_Len` defaults to `0` ("unlimited"), contradicting design.md §2.2:

> *"Maximum length: specifiable via –clen command line argument (default: 256 characters)."*

No startup assignment of 256 exists anywhere; `--clen`'s CLI parser only ever *sets* the value when
the flag is explicitly given. The user confirmed (session, 2026-08-23) that 256 has been the intended
default from the start and `0` reads as an unreplaced placeholder — the fix is to implement the
documented default, not correct the documentation.

Investigating this surfaced a second, related gap design.md §2.2 also covers, in its general
truncation rule (not scoped to any one statement):

> *"Truncation: If a string exceeds maximum length, a warning shall be issued and the string
> truncated from the right, keeping only the leftmost characters that fit."*

`LET`/`SET` (`sdata-interpreter-execute_assignment.adb:144-152`) already implements this correctly —
warns, then truncates. But every *other* path that writes a value into a table column —
`USE`-loaded CSV/ODF/OOXML data, `MERGE`, `AGGREGATE`/`TRANSPOSE` output, anything reaching
`Set_Value_Upper`/`Set_Output_Value*` — goes through `Table.Coerce_Value`
(`sdata_core-table.adb:237-251`), which truncates silently: no `Put_Line`/`Put_Line_Error` anywhere
in that function. Confirmed empirically: `--clen 50` loading a CSV with a 300-character field
truncates to 50 with zero warning, while the identical `--clen 5` on a `LET` literal warns correctly.

**Why this can't ship separately from the default fix:** today the silent-load-truncation gap only
affects someone who has already opted into `--clen` explicitly. The moment the default becomes 256,
it fires for *any* `USE` of a dataset with a string field over 256 characters — silently, by
default, for every user, for the first time. Shipping the default alone would make this fix itself
the cause of a new silent-data-loss surface. User decision (session, 2026-08-23): fold both into one
workstream.

## Decision

1. **`SData_Core.Config.Max_String_Len`'s default changes from `0` to `256`.** `--clen`'s existing
   parser logic is unchanged — it still only *overrides* the value when the flag is given; `0`
   remains a valid, explicit "no limit" choice via `--clen 0` (the parser already accepts `0` as a
   non-negative integer; this ADR does not change that — a script author who genuinely wants
   unlimited-length strings still has a way to ask for it).
2. **`Table.Coerce_Value` gains a truncation warning**, printed via `SData_Core.IO.Put_Line_Error`
   before returning the truncated value — the same house pattern already used by
   `Handle_Domain_Error` (`sdata_core-evaluator.adb:209-217`), a function whose job includes a
   side-effecting warning print, not a new pattern invented for this fix.
3. **Message text is byte-identical to `LET`/`SET`'s existing wording**:
   `"Warning: String truncated to <n> characters."` — no column name added, despite
   `Coerce_Value` having `Col_Name` available. One consistent message shape for "a string got
   truncated," matching the principle that the *reason* (exceeded `--clen`) is what a script author
   needs to recognize, not which of the many possible write paths triggered it.
4. **Warning granularity: per-occurrence, matching `LET`/`SET` exactly — no throttling.** Every call
   to `Coerce_Value` that truncates prints one warning line, with no per-column or per-load
   deduplication. See Alternatives Rejected for the throttled option and why it's deferred rather
   than adopted.
5. **`man/man1/sdata.1`, `sdata_main.adb`'s `--help` block, and `sdata-help.adb`'s `HELP` block** all
   gain `"(default 256)"` in their `--clen` description, matching the adjacent `-m` flag's own
   existing inline-default style in the same `--help` block (`"-m <cells> ... 0 = unlimited"`). None
   of the three currently states a default at all (verified directly, not assumed) — this is closing
   a discoverability gap, not correcting stale drift.
6. **`tests/new_functions_test.cmd`** (line 35, `PRINT MAXLEN("x")`, no `--clen` given) and its
   expected output (`tests/expected/new_functions_test.out` line 16, currently `0`) are updated to
   reflect the new default — this is an in-scope fix to a test whose own comment (*"MAXLEN: 0 means
   unlimited (default, no --clen)"*) documents the exact assumption this ADR changes, not an
   unrelated pre-existing test left alone.

## Rationale

- `Handle_Domain_Error` is direct, in-repo precedent for "a function that computes a value also
  prints a warning as a side effect when a documented condition fires" — reusing it rather than
  restructuring `Coerce_Value`'s signature or its callers to thread a warning callback through.
- Per-occurrence granularity is simpler, requires no new state (no "have I already warned for this
  column this session" tracking, no reset-point decision for when that state clears), and matches
  what `LET`/`SET` already does today, unthrottled, without complaint. Design.md's own wording ("if
  a string exceeds maximum length, a warning shall be issued") reads most naturally as per-occurrence,
  not per-column-per-session.
- Verified (not assumed) that per-occurrence warning cannot double-fire for `LET`/`SET`: their own
  truncation happens in `execute_assignment.adb` *before* the (already-shortened) value is handed to
  `Set_Permanent`/`Set_Temporary`; by the time that value later reaches `Table.Coerce_Value` (at
  `RUN`'s flush-to-output step), it is already at or under the limit, so `Coerce_Value`'s own check
  (`S'Length > Max_String_Len`) is false and no second warning fires.

## Consequences

**Positive**

- Closes PC-5 exactly as documented in design.md's default-value passage.
- Closes the silent-load-truncation gap in the *same* passage's general truncation-warning rule,
  before the default-value fix would otherwise make it a routine, first-time-for-everyone surprise.
- `--clen` remains fully backward-compatible: any script or workflow that already passes an explicit
  `--clen` value (including `--clen 0` for unlimited) is completely unaffected by the default change.

**Negative**

- A bulk `USE` of a dataset whose column regularly exceeds 256 characters (e.g., a free-text notes
  field, thousands of rows) will now print one warning line per truncated value — potentially a lot
  of output, and each `Put_Line_Error` is a real (if small) I/O cost repeated per truncation. Judged
  acceptable for this project's actual scale (single-operator CLI, not an automated bulk pipeline;
  see `01-architect.md`'s Risk Assessment) rather than solved here — see Alternatives Rejected.
- `tests/new_functions_test.cmd`'s expected output changes as a direct, in-scope consequence, not
  drift discovered later.

## Alternatives Rejected

- **Throttle `Coerce_Value`'s warning to once-per-column-per-load**, matching the *shape* of
  `Warn_Reserved_Columns` (`sdata_core-commands.adb:1952-1969`, which warns once per reserved-keyword
  column at `USE` time) — rejected for now, not because it's a bad idea, but because it isn't a
  drop-in reuse of that precedent (which fires once at `USE` time over the whole column set for an
  unrelated reason — keyword collision, not truncation) and would require inventing new package-level
  state (a "columns already warned this session" set) with its own reset-point design question (at
  `NEW`? at `USE`? at `RUN`?) that has no existing analog in this codebase to copy. Introducing a new
  state-tracking pattern under this fix's scope, for a volume concern that is real but not yet
  demonstrated to be an actual operational problem at this project's scale, trades a small, contained
  fix for a larger one on speculation. If real usage shows the per-occurrence noise is a genuine
  problem, that becomes its own future workstream with real data motivating the throttle's design,
  rather than a guess made here.
- **Enrich the warning message with `Col_Name`** (available to `Coerce_Value` but not to `LET`/`SET`'s
  own check) — rejected in favor of message-text consistency; noted as a legitimate, deliberately
  not-taken option rather than an oversight.

## Related

- ADR-0010/ADR-0012/ADR-0014/ADR-0015 — the `Script_Error`-over-`Program_Error` convention series;
  not directly applicable here (`Coerce_Value`'s truncation is not an error condition — design.md
  explicitly treats it as a warn-and-continue case, not a hard failure), but this decision continues
  that series' general practice of aligning implementation with design.md's already-published intent
  rather than leaving a gap.
- sdata `.ssd/audits/2026-08-13-design-vs-implementation/report.md` finding PC-5.
- sdata `.ssd/features/pc5-clen-default/` — the workstream implementing this decision.
