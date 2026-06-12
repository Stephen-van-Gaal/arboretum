---
seam: heartbeat
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - heartbeat-liveness
related-designs:
  - docs/superpowers/specs/2026-06-11-heartbeat-sentinel-design.md
owns:
  - scripts/heartbeat.sh
---
<!-- owner: pipeline-contracts-template -->

# heartbeat — `heartbeat.sh` per-machine liveness sentinel contract

The seam between `scripts/heartbeat.sh` (sourced producer of branch-liveness
sentinels) and its consumers: the refresh hooks (`prompt-timestamp.sh`,
`pre-commit-branch-check.sh`) call `heartbeat_touch`; `workspace-collision-check.sh`
calls `heartbeat_branch_is_live` / `heartbeat_age_hours_for_branch` to split
`warn-reattach` from `warn-reclaim`.

## Producer

`scripts/heartbeat.sh` — producer-type: `script`, **sourced, never executed**.
Resolves the current branch + tree root with cheap `git` plumbing
(`git symbolic-ref`, `git rev-parse`) — deliberately **not** the full
`workspace-context` resolver, since `heartbeat_touch` runs on every Bash tool call.
Echoes no author-controlled content (liveness is boolean; age is an integer), so it
needs no scrub primitive. Mutates only files under the shared
`<main-tree-root>/.arboretum/heartbeat/`. `heartbeat_touch` is a **no-op when the
current branch carries no issue number** (e.g. `main`) or on detached HEAD.

## Consumer

The two refresh hooks call `heartbeat_touch || true` (a touch failure never changes
the hook's own exit). `workspace-collision-check.sh --issue N` calls
`heartbeat_branch_is_live <branch>` on the **specific colliding branch**: exit 0 →
a live session backs it (`warn-reattach`); exit 1 → no live session (`warn-reclaim`).
Querying the branch — not the issue — keeps the caller's own live session from
masking a dead sibling.

## Protocol shape

### Inputs

- `heartbeat_touch` — no args; self-resolves branch + tree root via `git` plumbing.
- `heartbeat_branch_is_live <branch>` — branch short-name.
- `heartbeat_age_hours_for_branch <branch>` — branch short-name.
- Env: `ARBO_HEARTBEAT_TTL_SECONDS` (default 14400), `ARBO_HEARTBEAT_HARD_CAP_SECONDS`
  (default 604800), `ARBO_HEARTBEAT_DEBOUNCE_SECONDS` (default 60).

### Outputs

- Sentinel file `<main-tree-root>/.arboretum/heartbeat/<branch-slug>.json` =
  `{branch, worktree_path, last_seen, last_seen_iso}` (`last_seen` epoch seconds).
- `heartbeat_branch_is_live` returns exit 0 if the branch's sentinel is within TTL,
  exit 1 otherwise (no stdout).
- `heartbeat_age_hours_for_branch` echoes integer hours since last-seen, or nothing.

### Invariants

- `heartbeat_touch` writes nothing when the branch maps to no issue (or detached HEAD).
- `heartbeat_touch` is debounced: a sentinel written within `ARBO_HEARTBEAT_DEBOUNCE_SECONDS` is not rewritten (keeps the per-Bash-call hot path cheap).
- A sentinel with `now - last_seen > ARBO_HEARTBEAT_TTL_SECONDS` is **not** live.
- `heartbeat_branch_is_live` queries the named branch only — never "any branch for the issue".
- `heartbeat_touch` prunes sentinels older than `ARBO_HEARTBEAT_HARD_CAP_SECONDS`.
- Sentinels are anchored on the shared main-tree root (`dirname(git --git-common-dir)`), visible across worktrees.

## Test surface

`scripts/_smoke-test-contract-heartbeat.sh` (tmp-dir fixtures, offline). Auto-discovered
by `ci-checks.sh`'s `_smoke-test-*` glob.

- **HBC-1: sentinel shape.** After `heartbeat_touch` on an issue branch, the sentinel
  JSON has `branch`, `worktree_path`, `last_seen` (integer), `last_seen_iso`.
- **HBC-2: non-issue no-op.** `heartbeat_touch` on a non-issue branch writes no sentinel.
- **HBC-3: liveness boundary.** Fresh sentinel → `heartbeat_branch_is_live` exit 0;
  sentinel aged past TTL → exit 1.
- **HBC-4: branch-specific.** A sentinel for `feat/715-foo` does not make a different
  branch (`feat/999-other`) read as live.

## Versioning

v1.0 — initial. Additive functions/fields bump minor; a changed function signature,
sentinel field meaning, or removed function bumps major.
