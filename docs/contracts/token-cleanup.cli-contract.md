---
script: scripts/token-cleanup.sh
version: 1.1
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

- `consolidate [--dry-run]` *(optional subcommand)* — one-shot migration of token
  artifacts scattered across sibling git worktrees into the central
  (main-checkout) store (#673, D28). Journey files move by their idempotent name
  (an existing central copy wins, the duplicate is dropped); ledger files (live +
  archived) are preserved into the central `token-ledger/archive/` under a
  worktree-prefixed name. Worktree discovery is bounded to `git worktree list`
  (never an unbounded filesystem walk). `--dry-run` lists planned moves and
  mutates nothing. Prints a one-line `N journey + M ledger file(s)` summary
  (no raw dumps, D5).

With no subcommand, behaviour is driven by environment variables:

- `ARBORETUM_STATE_DIR` *(optional override)* — root of the state tree; the
  ledger directory is `<state>/token-ledger`. When unset it defaults to the
  device-stable root from `scripts/lib/state-dir.sh` (the main checkout's
  `.arboretum`, not the invoking worktree's, #673), not a bare cwd-relative
  `.arboretum`.
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
- **CLI-3: consolidate migrates worktree artifacts.** Given a sibling worktree
  with scattered journey/ledger artifacts, `consolidate --dry-run` lists planned
  moves without mutating; `consolidate` moves them into the main checkout's store
  and consumes the source.

## Versioning

- **1.0** — initial contract: cleanup summary + ledger rotation (2026-06-06).
- **1.1** — state-dir resolution now device-stable (main-checkout-anchored,
  #673); add `consolidate [--dry-run]` migration subcommand (2026-06-08).
