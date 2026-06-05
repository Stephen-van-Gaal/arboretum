---
script: scripts/collect-review.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/land
  - type: script
    name: scripts/_smoke-test-collect-review.sh
  - type: script
    name: scripts/_smoke-test-contract-review-config.sh
related-designs:
  - docs/superpowers/specs/2026-06-04-request-review-config-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/collect-review.sh`

## Surface

Aggregates every PR comment surface into one backend-neutral normalized record
list plus a separate approval/vote channel, writes them to the per-PR run-state
ledger, and echoes the comment array. On `github` it reads review summaries,
inline review comments, conversation comments, and GraphQL thread state. On
`azure-devops` it reads PR threads, filtering `commentType:system` threads
(votes/pushes/merges) and mapping the seven ADO thread statuses onto the
3-state model. All comment bodies are control-char scrubbed at source.

## Protocol

### Arguments

```
collect-review.sh <pr> [--unanswered]
```

- `<pr>` (positional, required) — the pull request number (positive integer).
- `--unanswered` — print only `open`-status records with no reply.

### Environment

- `COLLECT_FIXTURE_DIR=<dir>` — read fixtures from `<dir>` instead of the
  network (`github`: `gh-*.json`; `azure-devops`: `ado-threads.json`).

### Normalized record

```
{ surface, backend, id, file, line, author, body, status, reply_handle, priority }
```

- `status` ∈ `open | resolved | none`.
- `priority` ∈ `P1 | P2 | P3 | null` (harvested from a reviewer self-label).
- `reply_handle` — surface-dependent. github inline: `{comment_id}` (a valid
  `in_reply_to` target); github review-summary and conversation: `null` (neither
  id is an `in_reply_to` target); ado thread: `{thread_id, parent_comment_id}`.

### Exit codes

- `0` — records collected (possibly empty) and ledger written.
- `2` — missing/invalid `<pr>` (non-integer), unknown flag, `<pr>` is not a pull
  request (live github), or unsupported backend.
- `3` — a live GitHub surface fetch failed (rate limit, transient error, missing
  permission). The ledger is **not** written — a partial ledger that silently
  drops a failed surface is worse than an explicit failure.

### Side effects

Writes `comments.json` and `approvals.json` under `.arboretum/land/<pr>/`
(gitignored). Live mode reads from `gh` / `az`. No git history mutation.

## Test surface

- **CLI-1: GitHub normalization.** Every GitHub surface (review summary, inline,
  conversation) is represented; statuses are 3-state; the approval channel
  carries each review's state.
- **CLI-2: ADO collection.** ADO threads normalize to `ado-thread` records;
  `commentType:system` threads are filtered; `active→open` and `fixed→resolved`.
- **CLI-3: `--unanswered`.** Returns open records with no reply; excludes
  resolved or replied records.
- **CLI-4: Control-char scrub.** A body containing a control character is
  scrubbed in the normalized output and the ledger.
- **CLI-5: Surface coverage.** A refactor cannot silently drop a surface — the
  smoke test asserts each non-empty surface is represented.
