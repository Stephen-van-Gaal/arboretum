---
script: scripts/read-session-journey.sh
version: 1.1
invokers:
  - type: script
    name: scripts/token-report.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-07-token-journey-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-session-journey.sh`

## Surface

Per-stage / skill / subagent token-cost reporter (token-journey design D1–D10).
Parses a single session transcript in JSONL form and, deterministically (zero
LLM inference), attributes each priced turn's cost to the active `stage → skill`
inferred from `Skill` tool-use turns. Each turn's cost is split into a **context**
cost (cache-read) and an **operation** cost (fresh input + cache-creation +
output), priced per model family from `scripts/lib/token-rates.sh` — the rate
table is passed in by the bash wrapper, never hard-coded in the analysis core.
Subagent transcripts under `<session>/subagents/agent-*.jsonl` roll up to their
originating `(stage, skill)` via a **depth-agnostic `parentUuid` fixpoint join**
(grandchildren resolve once their parent does); unresolvable chains warn on
stderr and fall back to `(pre-workflow)` without dropping cost. Also emits a
context-intake diagnostic ranking `tool_result` sources by carry-burden
(`bytes × turns-resident`). Bash senses the environment (rates, descriptor); the
inline `python3` heredoc is a pure function of its inputs.

## Protocol

### Arguments

```
read-session-journey.sh --transcript <file.jsonl> [--stdout] [--output-dir <dir>] [--descriptor <x>] [--format md|json]
```

- `--transcript <file.jsonl>` *(required)* — path to the session transcript.
  Missing or non-existent triggers a usage error to stderr and exit `2`.
- `--output-dir <dir>` *(optional; default is the device-stable
  `<state-dir>/token-journey`, where `<state-dir>` is resolved by
  `scripts/lib/state-dir.sh` — the main checkout's `.arboretum`, not the
  invoking worktree's, #673)* — directory for the written report artifact.
- `--descriptor <x>` *(optional)* — report name stem. When omitted, resolved by a
  best-effort cascade: open PR number > `$ISSUE` > branch number > session id.
- `--format md|json` *(optional, default `md`)* — report format. `md` is the
  human-readable table; `json` writes a machine-consumable structured object
  (`{totals, stages[], intake[]}`). With `--stdout`, `md` appends the artifact
  path as the last stdout line while `json` keeps stdout pure JSON and emits the
  path on stderr.
- `--stdout` *(optional)* — additionally print the full report body to stdout
  (and the artifact path on the final line). Without it, only a ≤3-line pointer +
  headline is printed (output inversion, D8).

### Exit codes

- `0` — transcript parsed, report artifact written, and pointer/body printed.
- `2` — `--transcript` not supplied or the named file does not exist.

### Side effects

**Writes one report artifact** to
`<output_dir>/<transcript-timestamp>-<descriptor>.<ext>`. The timestamp comes
from the transcript's last-message timestamp (not wall-clock), so re-running the
same transcript is deterministic and idempotent (same path, same bytes). Spawns
`python3` to parse the transcript and `git`/`gh` for the best-effort descriptor
cascade (the `gh pr view` probe may make a network call; offline/CI runs fall
through deterministically). Reads the named transcript and any sibling
`<session>/subagents/agent-*.jsonl` files.

## Test surface

- **CLI-1: stack attribution + cost split.** A transcript with a stage-skill turn
  (`arboretum:design`) and a nested skill turn (`superpowers:brainstorming`)
  attributes both under the `design` stage and prints a context/operation/total
  cost split priced from the family rate table.
- **CLI-2: depth-agnostic subagent join.** A child and grandchild subagent both
  roll up to the originating stage via the `parentUuid` fixpoint; a broken
  `parentUuid` warns on stderr without crashing.
- **CLI-3: context-intake diagnostic.** A large early `tool_result` tops the
  carry-burden ranking, labelled by its source tool-use.
- **CLI-4: deterministic idempotent persistence.** Re-running the same transcript
  yields the same artifact path and identical bytes; the filename carries the
  transcript-sourced timestamp.
- **CLI-5: output inversion.** The default run prints a pointer + headline only
  (no report body on stdout); `--stdout` dumps the full body.
- **CLI-6: missing transcript exits 2.** Invocation without a resolvable
  transcript exits `2` with a usage diagnostic.

Covered by `scripts/_smoke-test-token-journey.sh`.

## Versioning

- **1.0** — initial contract: per-stage/skill/subagent journey reporter with
  depth-agnostic subagent join, intake diagnostic, idempotent persistence, and
  output inversion (2026-06-07).
- **1.1** — default `--output-dir` is now device-stable, anchored at the main
  checkout via `scripts/lib/state-dir.sh` (#673) (2026-06-08).
