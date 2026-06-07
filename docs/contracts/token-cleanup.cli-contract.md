---
script: scripts/token-cleanup.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/cleanup (Step 3.5)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/token-cleanup.sh`

## Surface

End-of-cycle token-accounting summary + ledger rotation, invoked by `/cleanup`
(Step 3.5). Prints the per-contributor `diagnose` summary for the run's ledger
and — when a session transcript is available — the `billed` cache/cost split
and captured cache-bust events, then rotates the live run ledger into
`.arboretum/token-ledger/archive/` (pruned to the last 20 archives). Advisory:
it never blocks cleanup, and a missing ledger is reported and exits cleanly.

## Protocol

### Arguments

No positional arguments. Behaviour is driven by environment variables:

- `ARBORETUM_STATE_DIR` *(default `.arboretum`)* — root of the state tree; the
  ledger directory is `<state>/token-ledger`.
- `ARBORETUM_RUN_ID` *(default `session`)* — names the live ledger
  `<run>.jsonl` and the archive prefix.
- `ARBORETUM_TRANSCRIPT` *(optional)* — when set to an existing file, the
  `billed` and `busts` reports are also printed.

### Exit codes

- `0` — always on the documented paths: summary printed and ledger rotated, or
  no ledger present for the run (reported, nothing to do). The summary
  sub-reports are wrapped `|| true` so a reporter hiccup never changes the exit
  code.

### Side effects

Reads the run ledger and (optionally) the transcript. Spawns
`scripts/token-report.sh` for the summaries. Creates
`<state>/token-ledger/archive/`, moves the live ledger there with a UTC
timestamp suffix, and prunes archived ledgers beyond the most recent 20. No
network calls.

## Test surface

- **CLI-1: prints summary + rotates.** Given a populated run ledger, the helper
  prints the per-contributor summary, removes the live ledger from the active
  path, and leaves a timestamped copy under `archive/`.
- **CLI-2: missing ledger is a clean no-op.** With no ledger for the run, the
  helper reports nothing-to-do and exits `0` without creating an archive.

## Versioning

- **1.0** — initial contract: cleanup summary + ledger rotation (2026-06-06).
