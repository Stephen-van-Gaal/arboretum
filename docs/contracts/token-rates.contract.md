---
seam: token-rates
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - token-rate-usd-per-1m
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
owns:
  - scripts/lib/token-rates.sh
---
<!-- owner: pipeline-contracts-template -->

# token-rates — Per-Model Token Rate Table Contract

`scripts/lib/token-rates.sh` is a dependency-free, sourceable rate table that
maps a `(model, kind)` pair to a USD-per-1M-token rate. It is the single source
of pricing for the token-accounting layer: `token-ledger.sh` sources it to
price `model` rows, and `read-session-billed.sh` mirrors the same Opus rates for
the billed surface. The rates carry a dated note and must be re-verified on
change.

## Producer

`scripts/lib/token-rates.sh` — producer-type: `script`.

A side-effect-free library, sourced (never executed directly). It defines one
function, `token_rate <model> <input|output|cache_write|cache_read>`, which
echoes the matching per-1M USD rate. Model matching is substring-based (`*opus*`,
`*sonnet*`, `*haiku*`); an unknown model or kind echoes `0`.

## Consumer

`scripts/lib/token-ledger.sh` (and, by mirrored constants,
`scripts/read-session-billed.sh`) — consumer-type: `script`.

`token-ledger.sh` calls `token_rate "$model" input` to derive `est_cost` for
priced rows. Consumers depend on the fixed function signature and the
USD-per-1M unit.

## Protocol shape

### Inputs

Two positional arguments: a model name (substring-matched against the known
families) and a rate kind in the closed set `input | output | cache_write |
cache_read`.

### Outputs

A single numeric USD-per-1M-token rate printed to stdout. Unknown
model/kind combinations print `0`.

### Invariants

- The function signature and unit (USD per 1M tokens) are stable.
- An unrecognized model or kind always yields `0` (never an error exit).
- Rate values carry a dated note in the source and are re-verified on change.

## Test surface

- **TR-1: known model+kind.** `token_rate` returns the documented non-zero rate
  for a known `(family, kind)` pair (e.g. sonnet input → `3.00`).
- **TR-2: unknown yields zero.** An unrecognized model or kind yields `0`.
- **TR-3: drives est_cost.** When `token-ledger.sh` prices a sonnet row of
  1000 est-tokens, the resulting `est_cost` is `0.003` (1000 × 3.00 / 1e6).

## Versioning

- **1.0** — initial contract: per-model USD rate table (2026-06-06).
