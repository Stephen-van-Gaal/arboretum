---
seam: roadmap-maintain-scan
version: 1.1
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/roadmap/maintain-scan.sh
---
<!-- owner: pipeline-contracts-template -->

# roadmap-maintain-scan — `roadmap/maintain-scan.sh` Scan-JSON Contract

The seam between `scripts/roadmap/maintain-scan.sh` (which classifies open issues into `/roadmap maintain` action buckets and emits a scan JSON to stdout) and its downstream consumer `scripts/roadmap/maintain-apply.sh`, which reads that JSON (header: "Consumes scripts/roadmap/maintain-scan.sh output") and applies the high-confidence, reversible actions. The scanner's stdout is the protocol: a two-key JSON document (`buckets` + `counts`) whose bucket entries carry exactly `{number, title, evidence}`. This contract pins the top-level schema, the bucket name set and precedence, and the per-entry field shape so the applier never re-derives classification from raw issue/PR data.

## Producer

`scripts/roadmap/maintain-scan.sh` — producer-type: `script`.

Read-only classifier. Reads open tracker items and recently-merged PRs (live: configured tracker adapter; test: `--issues-file <path>` / `--prs-file <path>`), with `--as-of <YYYY-MM-DD>` overriding "today" for deterministic runs. The default GitHub adapter delegates to `gh issue list` and `gh pr list`. It cross-references issues against merged PRs (60-day window) and issue-body heuristics, plus an agent-ready decay pre-pass (body-SHA + `agent-prep:verified` marker, trusted-author gated), then assigns each issue exactly one bucket by a fixed precedence (first match wins):

`auto_close` → `soft_resolved` → `agent_ready_invalidated` → `agent_ready_stale` → `orphan` → `untriaged` → `unshaped_next` → `healthy`.

It emits a single JSON document to stdout. `buckets` carries one array per actionable bucket (every bucket except `healthy` — healthy issues are intentionally omitted from `buckets`); `counts` carries an integer per bucket including `healthy`. Evidence strings are deliberately restricted to controlled fields (issue/PR numbers, dates, day counts) and never embed untrusted `.title`/`.body` text, because evidence flows verbatim into tracker comment bodies in `maintain-apply.sh`.

Depends on `jq`, `shasum`, and (live mode) an available, authenticated tracker backend.

## Consumer

Consumer-type: `script`. One downstream consumer:

- **`scripts/roadmap/maintain-apply.sh`** (`--scan-file <path|->`) validates the JSON with `jq -e .`, then reads `.buckets[<bucket>][]` and projects `"\(.number)\t\(.evidence)"` per entry (`bucket_rows()`, ~line 46). It acts only on the `auto_close`, `soft_resolved`, and the two `agent_ready_*` buckets; it leaves `untriaged` and `unshaped_next` for the interactive skill flow. The `/roadmap maintain` skill (`skills/roadmap/SKILL.md` ~line 214) pipes the scanner's stdout to a temp file, then feeds it to the applier via `--scan-file`.

**Consumer obligations:**

- Consumers MUST treat the stdout as a single JSON document with top-level `buckets` and `counts` objects, and validate it (`jq -e .`) before use.
- Consumers MUST read per-issue data from `.buckets[<bucket>][]` as objects carrying `number`, `title`, and `evidence` — and MUST NOT assume `healthy` issues appear under `buckets` (they appear only in `counts`).
- Consumers MUST treat the bucket-name set and precedence as fixed; adding or removing a bucket key is a contract change.
- Consumers MUST NOT re-derive classification from raw issue/PR fields — the bucket assignment is the scanner's authority.

## Protocol shape

### Inputs

- Flags: `--issues-file <path>` and `--prs-file <path>` (test mode — open-issue / merged-PR JSON), `--as-of <YYYY-MM-DD>` (deterministic "today"), `-h|--help`.
- Live mode (no `--issues-file`): configured tracker item list + PR list; requires the tracker backend to be available and authenticated. For the default GitHub adapter this uses `gh issue list --state open` + `gh pr list --state merged`.
- No stdin.

### Outputs

- stdout: one JSON document:
  ```
  { "buckets": { "<bucket>": [ {"number":N,"title":"…","evidence":"…"}, … ], … },
    "counts":  { "<bucket>": N, … } }
  ```
  `buckets` contains the seven actionable buckets (`healthy` omitted); `counts` contains all eight buckets including `healthy`.
- stderr / exit: `0` on success; `2` on unknown arg; `1` on a missing `--issues-file`/`--prs-file` path or (live mode) unavailable/unauthenticated tracker backend.

### Invariants

- **Two-key top level.** stdout is a single JSON object with exactly `buckets` and `counts` at the top level.
- **Bucket name set.** The actionable bucket keys are exactly `auto_close`, `soft_resolved`, `agent_ready_invalidated`, `agent_ready_stale`, `orphan`, `untriaged`, `unshaped_next`. `counts` additionally carries `healthy`. Adding/removing a key is a contract change.
- **Entry shape.** Every `.buckets[<bucket>][]` element has exactly `number`, `title`, `evidence`. Evidence is a non-empty string for every bucketed issue.
- **Healthy omission.** Issues classified `healthy` appear only under `counts.healthy`, never under `buckets`.
- **Single bucket per issue.** Each open issue lands in exactly one bucket (first-match precedence); `counts` sums to the total open-issue count.
- **Controlled evidence.** Evidence strings reference only issue/PR numbers, dates, and day counts — never verbatim issue title/body — since they flow into comment bodies downstream.
- **Read-only.** The scanner never mutates tracker items, PRs, or repo files.

## Test surface

- **RMS-1:** A fixture board (`--issues-file`/`--prs-file`, fixed `--as-of`) → valid JSON with top-level `buckets` and `counts` objects.
- **RMS-2:** A closing-keyword PR reference lands its issue in `auto_close`; a non-closing mention lands in `soft_resolved`; an old, unlabelled issue lands in `orphan`; a no-horizon issue lands in `untriaged` — pinning bucket name set + precedence.
- **RMS-3:** Each `.buckets[<bucket>][]` entry carries `number`, `title`, and a non-empty `evidence`.
- **RMS-4:** A `healthy` issue is absent from `buckets` but counted in `counts.healthy`; `counts` sums to the total fixture issue count.
- **RMS-5:** An unknown flag exits 2.

## Versioning

- **1.1** (2026-05-31) — live item and PR reads flow through backend-neutral helper functions; GitHub remains the default adapter.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/roadmap/maintain-scan.sh` on this branch. Issue #303 (WS5 PR 7a).
