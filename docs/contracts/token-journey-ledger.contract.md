---
seam: token-journey-ledger
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - token-journey-ledger-row
related-designs:
  - docs/superpowers/specs/2026-06-09-live-token-journey-ledger-design.md
  - docs/superpowers/specs/2026-06-10-token-journey-push-ledger-design.md
owns:
  - scripts/lib/token-journey-ledger.sh
---
<!-- owner: pipeline-contracts-template -->

# token-journey-ledger — Per-Session Push Ledger Writer Contract

`scripts/lib/token-journey-ledger.sh` is the single writer of the append-only
per-session token-journey ledger at
`<state-dir>/token-journey-ledger/<session>.jsonl`. Sourced (never executed) by
the `Stop` hook. The row schema is the seam pinned here: the ledger tree-builder
(`scripts/render-ledger-journey.sh`) and the audit reconciler depend on exactly
these keys.

## Producer

`scripts/lib/token-journey-ledger.sh` — producer-type: `script`.

A sourceable library exposing:

- `journey_ledger_path <session_id>` — resolves the per-session ledger path under
  `<state-dir>/token-journey-ledger/` (`<state-dir>` via
  `scripts/lib/state-dir.sh`, main-checkout-anchored per #673), creating the dir.
- `journey_ledger_capture <transcript> <ledger> [--stage <stage>]` — reads
  assistant messages **after the ledger watermark** (the last `uuid` already in
  the file) and appends one row per new message carrying a `usage` block. Stage
  is the `--stage` override (live, from `active-stage-cache.json`) else inferred
  from the transcript's stage-skill invocations (test/reconciliation path).
  Skill is always inferred from `Skill` tool-uses and carried across captures via
  the last row's `skill`. Author-influenced strings (`model`, `stage`, `skill`)
  are control-char scrubbed via the shared `scrub-control-chars.sh` primitive.

## Consumer

`scripts/render-ledger-journey.sh` and the audit reconciler
(`scripts/read-session-journey.sh --transcript`, cross-check) — consumer-type:
`script`. They read the JSONL and group by the pinned keys; they never write it.

## Protocol shape

### Inputs

`journey_ledger_capture` takes a transcript path, a target ledger path, and an
optional `--stage <stage>` override. `journey_ledger_path` takes a session id.
The target path resolves under `<state-dir>/token-journey-ledger/` via
`scripts/lib/state-dir.sh` (`$ARBORETUM_STATE_DIR` when set, else the main
checkout's `.arboretum`, #673). Stage/skill strings are derived from the
transcript (skill always; stage when no `--stage` override) and scrubbed before
serialization. No other environment parameterizes the row.

### Outputs

One JSON object appended per **distinct assistant message** (deduped by message
id — see invariants):

```json
{"uuid":"…","mid":"…","ts":"…","model":"…","stage":"…","skill":"…",
 "billed":{"input":N,"output":N,"cache_read":N,"cache_write":N}}
```

`uuid` is the transcript-line id of the first line carrying the message (the
watermark resume key); `mid` is the message id (the dedup key). `billed` carries
**raw token counts** (priced at render via `token-rates.sh`, not frozen into the
ledger). `billed.cache_write` maps the transcript's `cache_creation_input_tokens`
— matching the field name `token-rates.sh` prices and the billed/journey readers
use, so no alias layer is needed.

### Invariants

- The required-key set is fixed: `uuid mid ts model stage skill billed`, with
  `billed` carrying `input output cache_read cache_write`. Consumers depend on it
  and a contract test guards it.
- **Dedup is by message id (`mid`), matching the transcript tree-builder**
  (`journey_render.process`). A single assistant message spans many transcript
  lines sharing one `message.id` but distinct `uuid`s, all carrying `usage`;
  deduping on `uuid` would multiply-count and break the
  ledger==transcript reconciliation (TJL-5). One ledger row per `mid`.
- Watermark = the last `uuid` already in the ledger; capture resumes reading
  after it. Combined with mid-dedup (the seen-set is rebuilt from the ledger's
  `mid`s), a re-fired or interrupted `Stop` neither double-counts nor leaves a
  gap.
- Appends are newline-delimited even after a mid-write crash (a newline-less
  partial final line gets a separator before the next append), so a killed
  capture cannot corrupt an existing row.
- Control characters never reach the serialized `model` / `stage` / `skill`
  fields — at the writer **and** re-scrubbed at the render consumer (defense in
  depth, CLAUDE.md).
- No `agent` field in Slice 1 (subagent attribution is added in Slice 2 / #722).

## Test surface

- **TJL-1: schema keys present.** A captured row carries every required key
  (`uuid mid ts model stage skill billed`, `billed.{input,output,cache_read,cache_write}`).
- **TJL-2: cache_write mapping.** A message with `cache_creation_input_tokens`
  populates `billed.cache_write` with that value.
- **TJL-3: control-char scrub.** A `skill`/`model` string with an embedded
  control character is stored scrubbed.
- **TJL-4: watermark resume + mid-dedup.** Capturing the same transcript twice
  yields no new rows; and a transcript with multiple lines sharing one
  `message.id` (distinct uuids, all priced) produces exactly one row for that id
  (matching the transcript builder's dedup).
- **TJL-5 (reconciliation, linchpin): ledger-tree == transcript-tree.** On a
  no-subagent fixture, the ledger tree-builder's `stage→skill→{ctx,op,turns}`
  equals the transcript tree-builder's within rounding.
- **TJL-6: consumer-side scrub.** A ledger row whose `stage`/`skill` carries an
  embedded control char renders a control-char-free report + stdout via
  `render-ledger-journey.sh` (defense in depth at the consumer).

## Versioning

- **1.0** — initial: push-ledger row schema + watermark-resumed capture (2026-06-10).
