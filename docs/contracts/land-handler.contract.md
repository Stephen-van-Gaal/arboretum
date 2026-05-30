---
seam: land-handler
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/land-handler.sh
---
<!-- owner: pipeline-contracts-template -->

# land-handler — `land-handler.sh` /land Phase-Decision Contract

The seam between `scripts/land-handler.sh` (the bash helper backing `/land`'s terminal-state and stall-state phases) and the `/land` skill (`skills/land/SKILL.md`), which captures the handler's stdout and branches its prose on the emitted keys. The handler's stdout is a single line of space-separated `KEY=VALUE` tokens; this contract pins the subcommand interface, the closed key/value vocabulary per subcommand, and the always-exit-0-on-decision guarantee so the skill never re-implements PR-state classification or guesses at an unrecognised token.

## Producer

`scripts/land-handler.sh` — producer-type: `script`.

Takes one of two subcommands plus a positional `<pr-number>`:

- **`check-terminal <pr-number>`** — Phase 1. Fetches PR state via `gh pr view` (one retry on transient failure; `FETCH_RETRY_SLEEP` shortens the retry sleep for tests). Classifies the PR as terminal (`MERGED`, `CLOSED`, head branch confirmed-deleted, or not-found) or not. Also detects warm-vs-cold entry by reading prior `/land summary` rows from the journey log via `read-journey-log.sh`.
- **`check-stall <pr-number>`** — Phase 2. Detects whether the PR has stalled: draft state, CI `ACTION_REQUIRED`, or head SHA unchanged across ≥2 prior Phase-3 iterations (suppressed by pending CI or fresh reviewer activity). Reads CI buckets via `gh pr checks` and reviewer activity via `gh api .../reviews` + `.../comments`.

Internally it sources nothing but invokes `scripts/read-journey-log.sh` (resolved from its own `SCRIPT_DIR`) to recover prior summary rows, and shells out to `gh` for PR state, CI checks, branch existence, and review activity. It depends on `gh` (installed + authenticated) and `python3` (JSON parsing). The `ISSUE` env var selects the journey-log issue; it defaults to `<pr-number>` so a standalone run reads/writes its own thread.

It **always exits 0** once it has emitted a decision line — including the `unknown`/`fetch-failed` degraded outcomes. Non-zero exit (`1`) is reserved for invocation errors: bad/missing subcommand, missing `<pr-number>`, or `gh` absent.

## Consumer

Consumer-type: `skill`. One downstream consumer:

- **`skills/land/SKILL.md`** runs `bash scripts/land-handler.sh check-terminal "$PR"` (Phase 1, ~line 68) and `bash scripts/land-handler.sh check-stall "$PR"` (Phase 2, ~line 83), reads the emitted `KEY=VALUE` tokens, and branches its prose: it keys on `terminal=`/`stall=` (true/false/unknown), `reason=`, and `entry=` to decide whether to surface a message, log a `summary` entry via `log-stage.sh`, and crucially whether to call `ScheduleWakeup`.

**Consumer obligations:**

- Consumers MUST parse stdout as space-separated `KEY=VALUE` tokens, keying on `terminal`/`stall` first, then `reason`, `entry`, and the head-SHA context fields.
- Consumers MUST treat `terminal=unknown` / `stall=unknown` as a hard stop — they MUST NOT call `ScheduleWakeup` against unknown state (termination wins over availability).
- Consumers MUST treat any `reason` value outside the documented closed set as unexpected and stop rather than continue.
- Consumers MUST NOT call `ScheduleWakeup` from inside the handler — that gate lives in `/land`'s Phase 3 prose; the handler never schedules.

## Protocol shape

### Inputs

- Subcommand: `check-terminal` | `check-stall` (required first arg). Any other → usage error, exit 1.
- `<pr-number>` positional (required; missing → exit 1).
- Env: `ISSUE` (journey-log issue, defaults to `<pr-number>`); `FETCH_RETRY_SLEEP` (retry-sleep override for `gh pr view`, default 10).
- Reads PR state, CI checks, branch existence, and review activity via `gh` (requires `gh` on PATH + auth + resolvable repo); reads prior summary rows via `read-journey-log.sh`. Needs `python3`.

### Outputs

- stdout: exactly one line of space-separated `KEY=VALUE` tokens.
  - **`check-terminal`:** `terminal=true|false|unknown`. When `terminal=true`: `reason=merged|closed|branch-deleted|not-found` and `entry=warm|cold`. When `terminal=false`: `entry=warm|cold`. When `terminal=unknown`: `reason=fetch-failed` or `reason=unexpected-state:<STATE>` (the latter also carries `entry=`).
  - **`check-stall`:** `stall=true|false|unknown`. When `stall=true`: `reason=draft|ci-action-required|head-sha-unchanged` (head-sha case also carries `head_sha_unchanged_count=<n>` and `current_head_sha=<sha>`). When `stall=false`: `next_head_sha_unchanged_count=<n>` and `current_head_sha=<sha>` (plus optional `reason=head-sha-unreadable|ci-pending|new-review-activity`). When `stall=unknown`: `reason=fetch-failed|ci-fetch-failed`.
- stderr: only on fatal invocation error (usage / missing pr-number / `gh` missing).
- Exit codes: `0` — a decision line was emitted (including `unknown`/`fetch-failed` degraded cases); `1` — invocation error (bad subcommand, missing `<pr-number>`, `gh` absent).

### Invariants

- **KEY=VALUE protocol.** Every decision line is space-separated `KEY=VALUE` tokens; the lead token is always `terminal=` (check-terminal) or `stall=` (check-stall).
- **Closed verdict set.** The lead value is always one of `true`, `false`, `unknown` — never a fourth token.
- **Closed reason set.** `reason` is drawn from the documented per-subcommand set; the handler never emits an undocumented reason.
- **Decision exits 0.** Once a verdict line is printed the script exits 0, even for `unknown`/`fetch-failed`. Exit 1 means the handler never reached a decision (invocation error).
- **No scheduling.** The handler never calls `ScheduleWakeup` and never writes the journey log — it only reads it; mutation and scheduling are the skill's job.
- **Entry detection is read-only.** `entry=warm|cold` is derived from prior `/land summary` rows via `read-journey-log.sh`; a read failure degrades to `cold`, never to an error.

## Test surface

- **LH-1:** `check-terminal` on a `MERGED` PR (gh stub) → `terminal=true reason=merged entry=...`, exit 0.
- **LH-2:** `check-terminal` on an `OPEN` PR whose head branch still exists → `terminal=false entry=...`, exit 0.
- **LH-3:** `check-terminal` on a not-found PR (gh stub emits "no pull request") → `terminal=true reason=not-found entry=...`, exit 0, no retry sleep stall (FETCH_RETRY_SLEEP=0).
- **LH-4:** `check-stall` on a draft PR → `stall=true reason=draft`, exit 0.
- **LH-5:** `check-stall` on a ready PR with green CI and no prior Phase-3 summary → `stall=false next_head_sha_unchanged_count=0 current_head_sha=<sha>`, exit 0.
- **LH-6:** Invocation errors: no subcommand → exit 1; known subcommand with no `<pr-number>` → exit 1.
- **LH-7:** `gh` absent from PATH → exit 1 with a `requires the gh CLI` diagnostic.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/land-handler.sh` on this branch. Issue #303 (WS5 PR 7a).
