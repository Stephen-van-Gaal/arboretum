---
seam: state-dir
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - arboretum-state-dir-path
related-designs:
  - docs/superpowers/specs/2026-06-08-token-artifact-centralization-design.md
owns:
  - scripts/lib/state-dir.sh
---
<!-- owner: pipeline-contracts-template -->

# state-dir — Arboretum State-Directory Resolver Contract

`scripts/lib/state-dir.sh` is a dependency-free, sourceable resolver for the
base directory under which arboretum's generated token/state artifacts live. It
exists so those artifacts are **device-stable across git worktrees** rather than
fragmented into each worktree's own `.arboretum/` and lost on
`git worktree remove` (#673). It is the single source of truth consulted by the
token-journey writer, the token ledger, and token cleanup.

## Producer

`scripts/lib/state-dir.sh` — producer-type: `script`.

A side-effect-free library, sourced (never executed directly). It defines one
function, `arboretum_state_dir`, which echoes the resolved base directory and
returns 0.

## Consumer

`scripts/read-session-journey.sh`, `scripts/lib/token-ledger.sh`, and
`scripts/token-cleanup.sh` — consumer-type: `script`.

Each sources the resolver and appends its own subtree (`/token-journey`,
`/token-ledger`). Consumers depend on the fixed function name, the
single-line stdout path, and the precedence order below.

## Protocol shape

### Inputs

- `$ARBORETUM_STATE_DIR` *(optional env)* — explicit override. When set and
  non-empty it is echoed verbatim and short-circuits all other resolution.
- Ambient git context (the main working tree = first entry of `git worktree list`).

### Outputs

A single line on stdout: the state-directory path. No trailing subtree — the
caller appends one.

### Resolution precedence (authoritative)

1. `$ARBORETUM_STATE_DIR` set + non-empty → echo it verbatim.
2. Inside a git repo → `<main-checkout>/.arboretum`, where the main checkout is
   the first entry of `git worktree list --porcelain`, canonicalized to a
   physical path (`pwd -P`). Identical from the main checkout, a linked worktree,
   or any nested subdirectory; robust under submodules / `--separate-git-dir`
   (where the common git dir is not the checkout's parent).
3. Otherwise (not a git repo) → the literal `.arboretum` (cwd-relative
   fallback; preserves prior standalone behaviour).

### Invariants

- Pure: no filesystem mutation, no `cd` leaking to the caller (subshell-scoped).
- Dependency-free: bash + git only; no external runtime deps (framework rule).
- Stable: same resolved path regardless of invocation cwd within one checkout.

## Test surface

- **SD-1: override wins.** `ARBORETUM_STATE_DIR` set → echoed verbatim,
  short-circuiting git resolution.
- **SD-2: main-checkout anchor.** Inside a git repo, resolves to
  `<main-checkout>/.arboretum` — identical from the main checkout, a linked
  worktree, and a nested subdirectory.
- **SD-3: non-repo fallback.** Outside any git repo, resolves to the
  cwd-relative `.arboretum`.
- **SD-4: end-to-end.** Journey + ledger writes invoked from a linked worktree
  land under the main checkout's `.arboretum`, not the worktree's own.

Covered by `scripts/_smoke-test-state-dir.sh` (SD-1–SD-3) and
`scripts/_smoke-test-token-artifact-centralization.sh` (SD-4).

## Versioning

- **1.0** — initial contract: device-stable state-dir resolver anchored at the
  main checkout (first `git worktree list` entry), with env override and non-repo
  fallback (2026-06-08, #673).
