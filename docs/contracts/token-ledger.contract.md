---
seam: token-ledger
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - token-ledger-row
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
owns:
  - scripts/lib/token-ledger.sh
---
<!-- owner: pipeline-contracts-template -->

# token-ledger — Append-Only Token Ledger Writer Contract

`scripts/lib/token-ledger.sh` is the single writer of the append-only
per-contributor token ledger. It is sourced (never executed directly) by every
emit point — the document-access read helpers, `ci-checks.sh`, and per-step
model annotations — and exposes one function, `ledger_append`, that scrubs the
source id, estimates tokens via the chars/4 heuristic, optionally prices a
model row from the rate table, and appends one JSON object per call. The row
schema is the seam this contract pins (D2): consumers (`token-report.sh` and the
billed reader) parse exactly these keys.

## Producer

`scripts/lib/token-ledger.sh` — producer-type: `script`.

A sourceable library defining `ledger_append <contributor> <source> <bytes>
[model] [est_cost]`. Source ids are scrubbed of ASCII control characters
(defense in depth — they are author-influenced). The ledger path resolves from
`$ARBORETUM_TOKEN_LEDGER`, else `${ARBORETUM_STATE_DIR:-.arboretum}/token-ledger/<run>.jsonl`.
When a model is given and no explicit cost, the writer sources
`token-rates.sh` and computes `est_cost` from the input rate. Uses `jq` to
serialize each row.

## Consumer

`scripts/token-report.sh` and `scripts/read-session-billed.sh` —
consumer-type: `script`.

Consumers read the JSONL ledger and group/aggregate by the pinned keys. They
never write the ledger; the writer is the sole producer.

## Protocol shape

### Inputs

`ledger_append` takes a contributor label, a source id string, a byte count,
and optional `model` and `est_cost` arguments. Environment variables
(`ARBORETUM_RUN_ID`, `ARBORETUM_TS`, `ARBORETUM_WF`, `ARBORETUM_STAGE`,
`ARBORETUM_ISSUE`, `ARBORETUM_MODE`, `ARBORETUM_BUCKET`,
`ARBORETUM_TOKEN_LEDGER`, `ARBORETUM_STATE_DIR`) parameterize the row context
and target path.

### Outputs

One JSON object appended per call, carrying the required keys `run_id`, `ts`,
`workflow`, `stage`, `contributor`, `bucket`, `source`, `bytes`, `est_tokens`
(plus `issue`, `git_sha`, `mode`, and conditionally `model` / `est_cost`).
`est_tokens` is `bytes / 4`. Source ids are scrubbed of control characters.

### Invariants

- The required-key set is fixed; consumers depend on it and a contract test
  guards it.
- `est_tokens` always equals integer `bytes / 4`.
- Control characters never reach the serialized `source` field.
- `est_cost` is present only when a model was priced (or supplied).

## Test surface

- **TL-1: schema keys present.** A `ledger_append` call produces a row carrying
  every required key (`run_id ts workflow stage contributor bucket source bytes
  est_tokens`).
- **TL-2: chars/4 estimate.** A 12-byte source yields `est_tokens` of `3`.
- **TL-3: control-char scrub.** A source id containing an embedded control
  character is stored scrubbed.
- **TL-4: priced model row.** Appending with a model populates `model` and an
  `est_cost` derived from the rate table.

## Versioning

- **1.0** — initial contract: ledger row schema + writer (2026-06-06).
