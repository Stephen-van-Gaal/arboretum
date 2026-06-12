---
seam: workspace-collision-check
version: 3.0
producer-type: script
consumer-type: skill
consumes:
  - workspace-context
  - scrub-control-chars
  - heartbeat
produces:
  - collision-verdict
related-designs:
  - docs/superpowers/specs/2026-06-09-collision-mvp-design.md
  - docs/superpowers/specs/2026-06-09-cross-tool-signals-design.md
  - docs/superpowers/specs/2026-06-11-heartbeat-sentinel-design.md
owns:
  - scripts/workspace-collision-check.sh
---
<!-- owner: pipeline-contracts-template -->

# workspace-collision-check — collision verdict producer contract

The seam between `scripts/workspace-collision-check.sh` (producer of the
`VERDICT=` token) and its consumers: `skills/start/SKILL.md` (`--issue N`, rich)
and `.claude/hooks/pre-commit-branch-check.sh` (`--pre-commit`, narrow).

## Producer

`scripts/workspace-collision-check.sh` — producer-type: `script`. Sources
`workspace-context.sh` (fails closed if it can't). Scrubs all author-controlled
strings via the shared `scrub-control-chars` primitive before emitting them.

## Consumer

Two consumers. `/start` reads the token and acts advisorily: `warn-reattach` →
offer reattach (a live session backs the branch); `warn-reclaim` → surface the
orphaned worktree path + offer reclaim-or-fork (no live session backs the branch,
#715 — distinct from reattach-into-live); `warn-crosstool` → coordinate with Codex
(explicitly **not** reattach — a detached Codex worktree is not an attachable branch).
The pre-commit hook maps `warn-reattach` → exit 0 + advisory stderr (non-blocking)
and never blocks on the collision case. `--pre-commit` never emits `warn-reclaim`
(liveness is an `--issue`-mode signal only).

## Protocol shape

### Inputs

`workspace-collision-check.sh (--issue N | --pre-commit)`. Optional test seam:
`ARBO_COLLISION_ISSUE_JSON` (fixture path; `--issue` mode reads the recorded
claim from it instead of the tracker).

### Outputs

- stdout: exactly one line `VERDICT=clear|warn-reattach|warn-reclaim|warn-crosstool|block`.
- stderr: human-readable reason (diagnostic, not user chrome).

### Invariants

- Exit `0` whenever a verdict is computed (including `block`); exit `≥1` only on
  operational error (bad args, not a git repo, unsourceable helper).
- `--pre-commit` performs no network I/O and reads no recorded claim.
- Author-controlled output is control-char scrubbed.

## Test surface

`scripts/_smoke-test-contract-workspace-collision-check.sh` (bare-repo fixtures,
offline via the `ARBO_COLLISION_ISSUE_JSON` seam). Auto-discovered by
`ci-checks.sh`'s `_smoke-test-*` glob.

- **CWCC-1: exit-code contract.** Bad/empty args → exit 1 (operational error),
  distinct from a computed verdict's exit 0.
- **CWCC-2: token grammar.** stdout is exactly one `VERDICT=clear|warn-reattach|warn-reclaim|warn-crosstool|block`
  line; exit 0 when a verdict is computed.
- **CWCC-3: mapping — recorded claim + live sentinel → warn-reattach.** A `branch:`
  claim on the issue (read from the fixture JSON) **backed by a fresh heartbeat
  sentinel** yields `warn-reattach`. (A claim without a live sentinel yields
  `warn-reclaim` — see CWCC-7.)
- **CWCC-4: mapping — live worktree → block.** A branch for the issue checked out
  in another worktree yields `block`.
- **CWCC-5: `--pre-commit` is local-only.** With ≥2 on-disk branches for the
  current branch's issue, `--pre-commit` yields `warn-reattach` without reading the
  network or the recorded claim.
- **CWCC-6: mapping — detached Codex worktree → warn-crosstool.** A detached
  linked worktree under `$CODEX_HOME/worktrees/` whose HEAD is the tip of a branch
  for the issue yields `warn-crosstool` (`--issue` mode only). `warn-crosstool`
  outranks `warn-reattach` (the correlating branch co-triggers reattach); `block`
  still outranks `warn-crosstool`.
- **CWCC-7: liveness split (#715).** A `branch:` claim with a fresh heartbeat
  sentinel yields `warn-reattach`; the same claim with a stale or absent sentinel
  yields `warn-reclaim`. Precedence: `block > warn-crosstool > warn-reattach >
  warn-reclaim > clear` (`--issue` mode).

## Versioning

v1.0 — initial. Additive modes/signals bump minor; a changed verdict token,
output-contract change, or removed mode bumps major.

v2.0 — added the `warn-crosstool` token (#714); strict-grammar consumers must
accept it. New precedence `block > warn-crosstool > warn-reattach > clear`
(`--issue` mode). Major because the output grammar changed.

v3.0 — added the `warn-reclaim` token (#715); strict-grammar consumers must
accept it. The `--issue` claim path now splits on heartbeat liveness:
`warn-reattach` (live) vs `warn-reclaim` (stale/absent). New precedence
`block > warn-crosstool > warn-reattach > warn-reclaim > clear`. Major because
the output grammar changed.
