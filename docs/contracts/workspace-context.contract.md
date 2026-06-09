---
seam: workspace-context
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - scrub-control-chars
produces:
  - workspace-context-vars
related-designs:
  - docs/superpowers/specs/2026-06-07-workspace-context-helper-design.md
owns:
  - scripts/workspace-context.sh
---
<!-- owner: pipeline-contracts-template -->

# workspace-context — `workspace-context.sh` Tree-Root + Base + Branch Resolver Contract

The seam between `scripts/workspace-context.sh` (sourced producer of the `ARBO_*`
workspace variables) and its consumers — the base-detection bash blocks in
`consolidate`, `finish`, `pr`, `ai-surface-review`, and `cleanup` SKILL.md files.
Pins the variable contract and base-resolution semantics so a consumer can never
silently resolve diffs against stale local `main` (#381).

## Producer

`scripts/workspace-context.sh` — producer-type: `script`, **sourced, never executed**.
Source-time effects are limited to defining functions and loading the
`scrub-control-chars` primitive (it runs no git and mutates no repo until a function
is called); if the scrub primitive cannot load, sourcing **fails closed** (returns
non-zero, defines no API) rather than degrading the scrub guarantee silently. Reuses
`refresh-workspace-cache.sh`'s remote-resolution (origin-preferred, else first remote)
and scrubs all author-controlled strings (branch, default-branch, tree-root, **remote**)
of control characters via the sourced `scrub-control-chars` primitive before they enter
Claude's context.
Makes no repo mutations: base resolution is a read-only probe (never `git remote
set-head`); `git fetch` runs only under explicit `--fetch`.

## Consumer

Consumer-type: `skill` (SKILL.md bash blocks). Each consumer:

- MUST source the helper and use `$ARBO_BASE_REF` (a `<remote>/<default>`
  remote-tracking ref) as the base for `git diff`/`git log`/`git merge-base`,
  never a bare short name resolving to local `main`.
- MUST treat helper stderr warnings (local-fallback, fetch-failed) as diagnostics,
  not user-facing output (D8).
- `cleanup` MUST keep its `git branch --merged "$ARBO_DEFAULT_BRANCH"` semantics —
  it migrates the *resolution* only (D6).
- Ship-tail consumers (`finish`, `pr` pre-PR) MAY pass `--fetch` for a
  guaranteed-fresh base; high-frequency consumers (`consolidate`,
  `ai-surface-review`) MUST NOT (latency).

## Protocol shape

### Inputs

`workspace_context [--fetch]` and getters. Optional env: `$ARBO_WORKSPACE_FETCH_TIMEOUT`
(default 5s, shared with `refresh-workspace-cache.sh`); `timeout`/`gtimeout` for the
bounded fetch (degrades to best-effort no-timeout fetch if absent).

### Outputs

`workspace_context` sets in the caller's shell: `ARBO_TREE_ROOT`, `ARBO_BRANCH`
(empty on detached HEAD), `ARBO_DEFAULT_BRANCH`, `ARBO_BASE_REF`, `ARBO_BASE_SOURCE`
(`remote-head|remote-main|remote-master|local-fallback` — remote-agnostic; `ARBO_REMOTE` carries the actual remote name), `ARBO_REMOTE`,
`ARBO_WORKSPACE_CACHE`. Getters each echo exactly one value for `$(...)` use:
`workspace_tree_root`, `workspace_branch`, `workspace_default_branch`,
`workspace_base_ref [--fetch]`, `workspace_cache_path`.

### Invariants

- `ARBO_BASE_REF` is a remote-tracking ref whenever a remote-tracking base exists;
  only `local-fallback` yields a local ref, and only then with a stderr #381 warning.
- Base resolution writes nothing to the repo.
- `workspace_context` returns non-zero with empty vars when not inside a git work tree.
- Detached HEAD → `ARBO_BRANCH=""`; tree-root, base, remote still resolve.
- Author-controlled output is control-char-scrubbed.

## Test surface

`scripts/_smoke-test-contract-workspace-context.sh` (bare-repo fixtures, no network
except WSC-7's local bare remote). Auto-discovered by `ci-checks.sh`'s `_smoke-test-*`
glob.

- **WSC-1: tree-root is the linked worktree.** `workspace_tree_root` resolves to
  the current worktree's physical path, not the main checkout.
- **WSC-2: current branch.** `workspace_branch` echoes the short branch name.
- **WSC-3: cache path.** `workspace_cache_path` is `<tree-root>/.arboretum/workspace-cache.json`.
- **WSC-4: remote-tracking base (origin/HEAD set).** `workspace_base_ref` echoes
  `origin/main` when `origin/HEAD` is set.
- **WSC-5: fall-through to the tracking ref.** With `origin/HEAD` unset,
  `workspace_base_ref` still echoes the `origin/main` remote-tracking ref.
- **WSC-6: local fallback + #381 warning.** With no remote-tracking base, the getter
  echoes a local ref and emits a `#381` stale-base warning on stderr. The source
  classification (`ARBO_BASE_SOURCE` ∈ `remote-head|remote-main|local-fallback`) is a
  `workspace_context` output, asserted via the master resolver.
- **WSC-7: `--fetch` advances the tracking ref.** Against a local bare remote,
  `workspace_base_ref --fetch` updates `refs/remotes/<remote>/<default>`.
- **WSC-8: master resolver + failure modes.** `workspace_context` sets all `ARBO_*`;
  detached HEAD → empty `ARBO_BRANCH` with base still resolving; control characters
  scrubbed from author-controlled output; not-a-git-repo → non-zero with empty vars.
- **WSC-9: cross-shell sourcing.** The helper sources cleanly under zsh (where
  `${BASH_SOURCE[0]}` is empty) — scrub primitive loads and the base ref resolves.
- **WSC-10: remote name scrubbed.** An author-controlled remote name carrying a C1
  control byte is stripped from `workspace_remote` / `ARBO_REMOTE`.
- **WSC-11: fail-closed scrub load.** Sourcing the helper without a reachable
  `scrub-control-chars.sh` returns non-zero (no silent unscrubbed/empty pass-through).

## Versioning

v1.0 — initial. Additive variable/getter changes bump minor; a changed
variable meaning or removed getter bumps major.
