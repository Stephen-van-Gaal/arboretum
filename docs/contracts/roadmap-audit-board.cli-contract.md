---
script: scripts/roadmap/audit-board.sh
version: 1.1
invokers:
  - type: skill
    name: arboretum:/roadmap
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/roadmap/audit-board.sh`

## Surface

Read-only issue bucket classifier. Given an open-issue board as JSON (via `--board-file` or a live tracker issue-list call), categorizes every issue into one of five buckets (`active`, `well_scoped`, `inbox`, `speculative`, `other`) using a label + recency ruleset and emits a single JSON object to stdout. Accepts `--as-of <YYYY-MM-DD>` to pin "today" for deterministic test runs. Intended as the classification back-end for the `/roadmap` skill and for developer diagnostics. Callers consume the `counts` or `by_bucket` maps from stdout to drive orientation views and board-hygiene decisions.

## Protocol

### Arguments

```
audit-board.sh [--board-file <path>] [--as-of <YYYY-MM-DD>] [-h|--help]
```

- `--board-file <path>` *(optional)* — read open-issue JSON from file instead of calling the configured tracker. The file must contain a JSON array of issue objects each with fields: `number`, `title`, `labels` (array of `{name}` objects), `createdAt`, `updatedAt`, `comments` (count or 0), `milestone`. When supplied, the live backend guards are bypassed entirely. If the path does not refer to an existing file the script exits 1 with `Not a file: <path>` on stderr.
- `--as-of <YYYY-MM-DD>` *(optional)* — override the reference date used to compute `days_since` deltas. Defaults to today's UTC date (`date -u +%Y-%m-%d`). Used to make fixture-driven tests deterministic.
- `-h` / `--help` *(optional)* — print the embedded usage comment and exit 0.
- Any unrecognised argument causes the script to print `Unknown arg: <arg>` to stderr and exit 2.

Flag parsing is strictly positional-to-named; all flags must appear before any argument that is not a flag value.

### Exit codes

- `0` — categorization completed successfully; JSON emitted to stdout.
- `1` — one of: (a) `--board-file` path does not exist (`Not a file: <path>` on stderr); (b) configured tracker backend unavailable or unauthenticated; (c) an unexpected `set -euo pipefail` subcommand failure propagates (undocumented value — not part of the contract).
- `2` — unknown argument supplied (`Unknown arg: <arg>` on stderr).

### Side effects

Read-only — no side effects. The script performs no disk writes and spawns no persistent processes. In live mode it issues one tracker issue-list network call. In `--board-file` mode there are no network calls. All categorization output goes to stdout. Stderr output occurs only on the error paths documented above.

## Test surface

- **CLI-1: File-driven mode produces valid JSON.** Invoking with `--board-file <fixture>` exits 0 and emits a single JSON object whose top-level keys are exactly `issues`, `by_bucket`, and `counts`.
- **CLI-2: Bucket assignment — five-bucket ruleset.** Given a fixture containing one issue per bucket archetype and a pinned `--as-of` date, each issue is assigned its expected bucket. Specifically: a stale unlabelled issue (no `horizon:*`, `updatedAt` >60 days before `--as-of`) → `speculative`; a freshly created issue (no `horizon:*`, `createdAt` within 7 days of `--as-of`) → `inbox`; an issue with `type:*` and `horizon:*` labels and no `blocked` label → `well_scoped`; an issue with `horizon:now` and `updatedAt` within 14 days → `active`; an issue with the `blocked` label → `other`.
- **CLI-3: `blocked` label takes precedence.** An issue that also carries `horizon:now` and was recently updated is bucketed as `other` (not `active`) when the `blocked` label is present, confirming the top-of-ruleset precedence.
- **CLI-4: `counts` sums to total issue count.** The values in `.counts` sum to the total number of issues in the input array.
- **CLI-5: Unknown argument → exit 2.** Invoking with an unrecognised flag (e.g. `--bogus`) exits 2 with no stdout.

## Versioning

- **1.1** (2026-05-31) — live board reads flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** — initial contract (2026-05-30).
