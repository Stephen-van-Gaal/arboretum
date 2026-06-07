---
script: scripts/token-scenario.sh
version: 1.0
invokers:
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/token-scenario.sh`

## Surface

Deterministic testbed A/B fixture runner. Replays a declared list of bounded
document reads against the document-access helpers with `ARBORETUM_MODE` forced
to `testbed`, so the resulting ledger rows are tagged `mode:testbed` and form a
reproducible substrate for before/after token experiments. Advisory and
side-effect-free beyond the ledger it writes through the instrumented reads.

## Protocol

### Arguments

```
token-scenario.sh [--reads <doc>:<section>]...
```

- `--reads <doc>:<section>` *(repeatable)* — a colon-separated document path and
  section heading to replay via `scripts/read-doc-section.sh`. Each occurrence
  performs one bounded read whose instrumentation appends a `mode:testbed`
  ledger row. Unknown flags are ignored.

The run id defaults to `scenario` (overridable via `$ARBORETUM_RUN_ID`); the
ledger path follows `$ARBORETUM_TOKEN_LEDGER` when set.

### Exit codes

- `0` — the scenario completed. Individual read failures are swallowed
  (`|| true`) so a missing section never aborts the run; the runner always
  prints its completion line and exits `0`.

### Side effects

Sets and exports `ARBORETUM_MODE=testbed` and `ARBORETUM_RUN_ID` for the
spawned reads. Each `--reads` spawns `scripts/read-doc-section.sh`, whose
advisory instrumentation appends a row to the active token ledger. Prints a
single completion line naming the ledger. No network calls.

## Test surface

- **CLI-1: testbed tagging.** A `--reads <doc>:<section>` scenario appends a
  ledger row whose `mode` field is `testbed`.
- **CLI-2: read failures are non-fatal.** A `--reads` naming a missing section
  does not abort the run; the runner still exits `0`.

## Versioning

- **1.0** — initial contract: testbed A/B reads scenario runner (2026-06-06).
