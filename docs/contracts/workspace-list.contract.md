---
seam: workspace-list
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - workspace-context
produces:
  - worktree-list-json
related-designs:
  - docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md
owns:
  - scripts/workspace-list.sh
---
<!-- owner: pipeline-contracts-template -->

# workspace-list — `workspace-list.sh` Worktree Enumerate + Resolve Contract

The sourced data half of the `/workspace` skill: enumerate the repo's worktrees
(enriched for orientation) and resolve a switch selector to a single worktree
path. Creation is **not** here — it is owned by the `/start` seam. Source of
truth is `git worktree list`; the workspace cache provides best-effort
enrichment.

## Producer

`scripts/workspace-list.sh`, sourced (never executed). Sources
`workspace-context.sh` (which loads the scrub primitive and provides
`workspace_tree_root` / `workspace_cache_path`); fails closed if that source
fails.

## Consumer

`skills/workspace/SKILL.md` (`/workspace list` and `/workspace switch`). May also
be sourced by the session-start banner producer for the worktree-map block.

## Protocol shape

### Inputs

`workspace_list_json` — no arguments. `workspace_resolve_target <selector>` —
one selector: a worktree path, a branch name, or an issue number.

### Outputs

- **WL-1: `workspace_list_json`** — emits a JSON array (one object per worktree):
  `{ path, branch, current, dirty, issue, open_pr }`.
  - `current` — `true` iff `path` equals `workspace_tree_root` (the invoking
    session's worktree); exactly one entry is current.
  - `dirty` — `git status --porcelain` non-empty in that worktree.
  - `issue` — integer parsed from a `feat|fix|chore|docs/<N>-…` branch, else `null`.
  - `open_pr` — the cache's `open_pr` object, but only for the cache's
    `current_branch` (the cache carries `open_pr` for the current branch only);
    `null` otherwise.
- **WL-2: `workspace_resolve_target`** — echoes exactly one worktree path on
  stdout. Precedence: exact path → exact branch → issue number; first tier with a
  match wins. Exit `1` with a stderr message on no match or ambiguity (>1 match
  in the winning tier).

### Invariants

- **Author-controlled strings are control-char-scrubbed at this render seam**
  (defense in depth, per CLAUDE.md): the branch name and the `open_pr.title` are
  scrubbed via `scrub_control_chars` even though the cache writer also scrubs —
  a hand-edited or older cache may carry a `\u`-escaped control char that is valid
  JSON on disk but renders raw.
- `git worktree list` is the source of truth for *which* worktrees exist; the
  cache only enriches. A missing/unreadable cache degrades to `open_pr: null`,
  never an error.
- Read-only: enumerates and resolves; never creates, removes, or mutates a
  worktree.

## Test surface

`scripts/_smoke-test-contract-workspace-list.sh` (git fixtures with multiple
worktrees; `jq`-gated SKIP when `jq` is absent). Auto-discovered by `ci-checks.sh`'s
`_smoke-test-*` glob.

- **WL-1:** `workspace_list_json` emits one object per worktree, marks exactly one
  `current`, parses the issue from a `feat/<N>-` branch, and scrubs an
  author-controlled PR title (a `\u`-escaped ESC) at the render seam.
- **WL-2:** `workspace_resolve_target` resolves by issue and by branch to the
  right worktree path, and exits 1 on a no-match selector.
- **WL-3:** zsh portability — `workspace_list_json` emits valid JSON under the
  user's zsh shell (no `local`-in-pipe-subshell leak corrupting the stream).

## Versioning

v1.0 — initial (`workspace_list_json`, `workspace_resolve_target`). Additive
fields/selectors bump minor; a changed field meaning or removed function bumps
major.
