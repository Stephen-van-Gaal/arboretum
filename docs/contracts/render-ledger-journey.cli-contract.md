---
script: scripts/render-ledger-journey.sh
version: 1.0
invokers:
  - type: script
    name: hooks/token-journey-session-end.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-09-live-token-journey-ledger-design.md
  - docs/superpowers/specs/2026-06-10-token-journey-push-ledger-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/render-ledger-journey.sh`

## Surface

Renders the token-journey report from a per-session **push ledger** (the second
tree-builder of epic #719 D3). It reads the ledger rows produced by
`scripts/lib/token-journey-ledger.sh`, builds the renderer's
`stage → skill → {ctx, op, turns}` tree, prices each row from
`scripts/lib/token-rates.sh`, and reuses the shared renderer core
(`scripts/lib/journey_render.py`) to write a bounded artifact. The transcript
parser (`read-session-journey.sh --transcript`) remains the independent audit
path; this driver is the live/auto path. The CONTEXT INTAKE section is **absent**
(the ledger carries no `tool_result` byte sizes — slice-1 DS1.3); intake analysis
stays on the audit path. Bash senses the environment (rates, descriptor); the
inline `python3` is a pure function of its inputs.

## Protocol

### Arguments

```
render-ledger-journey.sh --ledger <file.jsonl> [--stdout] [--output-dir <dir>] [--descriptor <x>] [--format md|json]
```

- `--ledger <file.jsonl>` *(required)* — path to a per-session push ledger.
- `--stdout` — also print the report body to stdout (else only the pointer line).
- `--output-dir <dir>` — artifact directory (default
  `<state-dir>/token-journey/`, main-checkout-anchored per #673).
- `--descriptor <x>` — filename descriptor (sanitized to `[A-Za-z0-9._-]`).
- `--format md|json` — report shape (default `md`).

### Outputs

- Writes one report artifact to `<output-dir>/<stamp>-<descriptor>.<fmt>`, where
  `<stamp>` is derived from the ledger's last `ts` — the filename is idempotent,
  so re-rendering an unchanged ledger overwrites the same file.
- **Output inversion (epic D8):** the report body goes to the file; only a
  ≤3-line pointer + headline reaches stdout, unless `--stdout` is given. In
  `--stdout --format json` mode the artifact path is emitted on stderr to keep
  stdout pure JSON.

### Invariants

- The audit path (`read-session-journey.sh --transcript`) is never invoked or
  modified by this driver.
- `intakes` is always empty for the ledger path; the renderer's intake block is
  guarded off (DS1.3) so no empty-section stub appears.
- Rates are read only from `token-rates.sh`; never hard-coded.
- Missing/unreadable ledger → exit 2 with a usage/diagnostic message; the
  invoking `SessionEnd` hook wraps the call in `|| true` so a failure never
  blocks session exit.

## Test surface

- Exercised by `scripts/_smoke-test-contract-token-journey-ledger.sh` (TJL-5
  reconciliation renders via this driver) and
  `scripts/_smoke-test-token-journey-push-integration.sh` (end-to-end render).

## Versioning

- **1.0** — initial: ledger tree-builder + render driver (2026-06-10).
