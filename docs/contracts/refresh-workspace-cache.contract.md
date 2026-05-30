---
seam: refresh-workspace-cache
version: 1.0
producer-type: script
consumer-type: hook
consumes:
  - workspace-cache-schema
  - session-start-cycle-state
  - module-contract-template-file
produces:
  - workspace-cache-json-schema
  - session-workspace-orientation-data
related-designs:
  - docs/superpowers/specs/2026-05-29-session-workspace-orientation-design.md
owns:
  - scripts/refresh-workspace-cache.sh
---
<!-- owner: pipeline-contracts-template -->

# refresh-workspace-cache — `refresh-workspace-cache.sh` Workspace Cache Producer Contract

The seam between `scripts/refresh-workspace-cache.sh` (the producer of `.arboretum/workspace-cache.json` — the cached snapshot of the git workspace dimension gathered on session start: current branch, dirty state, local-vs-remote drift, worktrees, open PR) and its sole downstream consumer `.claude/hooks/session-start.sh` (the `[Workspace]` block of the SessionStart hook's boot banner). This contract pins the cache schema so the renderer can never silently mis-parse a shape change — the exact #124-class coupling guard the contract pattern exists to enforce.

## Producer

`scripts/refresh-workspace-cache.sh` — producer-type: `script`.

Refreshes the cache at `.arboretum/workspace-cache.json` on every session open. Gathers **local facts** cheaply (no network): current branch, dirty state and count, `main` vs `main@{upstream}` drift, current branch vs its `@{upstream}`, worktrees, and local branch names. Then runs a **synchronous fetch** (5 s timeout per upstream, via `$ARBO_WORKSPACE_FETCH_TIMEOUT`, defaulting to 5) against each upstream's actual remote — never hardcoded `origin`. After the fetch, recomputes drift against the freshly-updated remote-tracking refs. Detects the **provider** from the `origin` URL (GitHub vs Azure DevOps vs unknown). Runs a **bounded PR lookup** (`gh pr list`) for GitHub origins only, bounded by the same `$ARBO_WORKSPACE_FETCH_TIMEOUT`; skipped when GNU `timeout` is unavailable (default macOS) or when the provider is not GitHub.

Path resolution uses a positional arg (defaults to `git rev-parse --show-toplevel` or `pwd`). The script writes the cache atomically via per-process `mktemp` + `mv` — concurrent refreshes never produce truncated or interleaved content.

The script **always exits 0** — degraded paths (not-a-git-repo, offline, python3-unavailable) write a minimal valid cache rather than failing.

All author-controlled string fields written into the cache are scrubbed of ASCII control characters (`\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f`) before serialization (the `_CTRL` regex in the python3 cache-builder, applied to branch name, worktree paths, and PR title/url/state).

## Consumer

One downstream consumer, consumer-type: `hook`:

- **`.claude/hooks/session-start.sh`** (hook). Reads `.arboretum/workspace-cache.json` on every session start and renders the `[Workspace]` block of the boot banner. The renderer branches on the cache shape and applies the routing precedence to recommend one of the session-open modes (A–E or C-silent).

**Consumer obligations:**

- The consumer MUST re-scrub all author-controlled string fields before render, as defense-in-depth against a hand-edited or older-version cache. The `_CTRL` regex applied at read time mirrors the one applied at write time.
- The consumer MUST NOT claim "(current ✓)" on main drift when `main.fresh` is `false` — stale refs cannot confirm freshness. The `fetch_ok` field and `main.fresh` together gate that claim.
- The consumer MUST apply the routing precedence: **detached → checkout · dirty → A · open-PR → E · recorded-branch-exists → B · main-behind → D · recorded-branch-missing → B(fresh) · next-up → B/D · else → C(silent)**.
- The consumer MUST render the `[Workspace]` block only when there is signal to carry (branch is not main, or drift, or dirty, or open PR, or next-up). On clean `main` with no drift, no WIP, no open PR, a successful fetch, and no next-up, the block is silent.
- The consumer MUST handle `error: "not-a-git-repo"` and `error: "python3-unavailable"` by silencing the block entirely.

## Protocol shape

### Inputs

`scripts/refresh-workspace-cache.sh` accepts one optional CLI argument:

- **`[project-dir]`** — positional, defaults to `git rev-parse --show-toplevel` or `pwd`. Sets the root under which `.arboretum/workspace-cache.json` is written.

Reads (under the project-dir root):

- `git rev-parse --is-inside-work-tree` — to detect whether the directory is a git repo. Absence triggers the not-a-git-repo early-exit path.
- `git symbolic-ref --quiet --short HEAD` — current branch (empty when detached HEAD).
- `git status --porcelain` — dirty state and count.
- `git worktree list --porcelain` — worktree inventory.
- `git for-each-ref --format='%(refname:short)' refs/heads` — local branch short-names.
- `git remote`, `git remote get-url <remote>` — primary remote and provider detection.
- `git rev-parse --abbrev-ref --symbolic-full-name 'main@{upstream}'` — main's configured upstream (falls back to `<primary-remote>/main` if unset and that ref exists — never assumed `origin`).
- `git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'` — current branch's upstream.
- `git rev-list --left-right --count <upstream>...<branch>` — drift counts, computed before and after fetch.
- `git fetch --quiet <remote> +refs/heads/<branch>:refs/remotes/<remote>/<branch>` — bounded per upstream (5 s default). Uses explicit destination refspecs so remote-tracking refs are genuinely updated.
- `gh pr list --head <branch> --state open --json number,url,title,state --jq '.[0] // empty'` — open PR lookup, GitHub origins only, bounded by `timeout "$FETCH_TIMEOUT"`. Skipped when `timeout` is unavailable or provider is not GitHub.
- `python3` — used for JSON assembly and scrubbing. Absence triggers the no-python3 fallback path with `error: "python3-unavailable"`.

### Outputs

Writes to `.arboretum/workspace-cache.json` (atomic via mktemp + mv). Cache shape:

```json
{
  "fetched_at": "<ISO-8601 UTC>",
  "fetch_ok": true | false,
  "provider": "github" | "azure-devops" | "unknown",
  "current_branch": "<branch-name, control-char-stripped>" | null,
  "dirty": true | false,
  "dirty_count": <int>,
  "main": { "behind": <int>, "ahead": <int>, "fresh": true | false } | null,
  "current_upstream": { "name": "<upstream-name, control-char-stripped>", "behind": <int>, "ahead": <int> } | null,
  "worktrees": [ { "path": "<path, control-char-stripped>", "branch": "<name, control-char-stripped>" | null } ],
  "local_branches": [ "<branch-name, control-char-stripped>", ... ],
  "open_pr": { "number": <int>, "url": "<url, control-char-stripped>", "title": "<title, control-char-stripped>", "state": "<state, control-char-stripped>" } | null,
  "error": null | "not-a-git-repo" | "python3-unavailable"
}
```

`current_branch: null` means detached HEAD. `main: null` means main has no known upstream and the fallback ref also doesn't exist. `current_upstream: null` means the current branch has no configured upstream. `open_pr: null` means no open PR found or enrichment skipped (provider not GitHub, `gh` absent, or `timeout` unavailable). `local_branches` lists local branch short-names — the renderer uses them to confirm a `/handoff`-recorded branch still exists before recommending "resume". Worktree entries carry `path` + `branch` only — `git worktree list --porcelain` does not report dirtiness, and computing it per worktree for data the v1 renderer doesn't consume is YAGNI.

Exit codes:

- `0` — always. Cache written successfully. Sub-cases: full success; degraded (offline/fetch-failed, `fetch_ok:false`); not-a-git-repo (minimal error cache); python3-unavailable (minimal error cache).

### Invariants

- **Output JSON shape.** The cache file is valid JSON with top-level keys `{fetched_at, fetch_ok, provider, current_branch, dirty, dirty_count, main, current_upstream, worktrees, local_branches, open_pr, error}`. No other top-level keys. Adding or removing a key is a contract change requiring a coordinated consumer update.
- **Always-exits-0 contract.** The script exits 0 even on degraded paths (not-a-git-repo, offline, python3-unavailable). The `error` field carries the failure reason; the exit code carries only "did the cache write succeed."
- **Always-writes-valid-JSON contract.** The cache file is never empty and is always valid JSON — including the no-python3 path (which writes a printf-built minimal cache) and the not-a-git-repo path (same). The no-python3 path writes `error: "python3-unavailable"` with safe null/false defaults; it never writes an empty file.
- **fetch_ok semantics.** `fetch_ok: false` means at least one attempted fetch did not reach its remote (timeout, network error, no remote). `fetch_ok: false` does NOT mean "local facts are unavailable" — local facts are always computed. When `fetch_ok: false`, the consumer MUST suppress "(current ✓)" and render "staleness unknown."
- **Freshness-per-comparison.** `main.fresh` is true only when the fetch of main's upstream succeeded. A failed current-branch upstream fetch sets `fetch_ok: false` but does NOT set `main.fresh: false` — per-comparison freshness prevents a missing feature-branch remote from poisoning the main staleness signal.
- **Provider-gated PR lookup.** The `gh pr list` call is made only when `provider == "github"` AND `gh` is on PATH AND GNU `timeout` is available. Azure DevOps origins never invoke `gh`. This is a deliberate design choice for v1; `open_pr: null` is the correct value for Azure origins.
- **Fetch-timeout bound.** The `gh pr list` lookup is bounded by `$ARBO_WORKSPACE_FETCH_TIMEOUT` (same 5 s default as the fetch), not an unbounded synchronous call.
- **ANSI-scrub invariant.** Author-controlled string fields are scrubbed of `\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f` before being written to the cache: `current_branch`, `current_upstream.name`, `worktrees[*].path`, `worktrees[*].branch`, `open_pr.title`, `open_pr.url`, `open_pr.state`, `local_branches[*]`. Consumer re-scrubs as belt-and-braces.
- **Worktrees-no-dirty invariant.** Worktree entries carry `path` and `branch` only. No `dirty` field — `git worktree list --porcelain` does not report dirtiness, and the v1 renderer does not consume it.
- **Atomic-write invariant.** The cache file is written via per-process `mktemp` + `mv` atomic rename. Concurrent refreshes never produce truncated or interleaved content.

## Test surface

- **RWC-1:** Producer always exits 0 and always writes a parseable JSON cache (even not-a-git-repo / offline / **python3-unavailable** — the no-python3 path writes a minimal cache with `error: "python3-unavailable"`, never an empty file).
- **RWC-2:** `error: "not-a-git-repo"` when run outside a work tree; all fact fields null/empty/false.
- **RWC-3:** Local facts correct: `current_branch` (null on detached HEAD), `dirty`/`dirty_count`, `main.{behind,ahead,fresh}` computed against `main@{upstream}` (fallback `<primary-remote>/main`, never assumed origin), `current_upstream` (null when no upstream). Freshness is tracked per comparison — a failed current-branch upstream fetch leaves `main.fresh` true.
- **RWC-4:** `fetch_ok` reflects whether the fetch reached the remote; offline run sets `fetch_ok:false` but still writes local facts.
- **RWC-5:** `provider` is `github` for github.com/GHE/proxy origins, `azure-devops` for dev.azure.com/visualstudio.com, `unknown` when no remote.
- **RWC-6:** Mode-E: GitHub origin with a stubbed open PR → `open_pr` object with `number/url/title/state`; Azure origin → `open_pr:null` with no `gh` invocation.
- **RWC-7:** All author-controlled strings (branch, worktree path, PR title/url) are control-char-scrubbed at write time. (Git ref names forbid control chars, so the *fixture* must inject one via a scrub-able field that can actually carry it — a worktree path or the stubbed PR title/url — not a branch name.)
- **RWC-8:** Consumer obligation: `session-start.sh` re-scrubs author-controlled fields before render; routing precedence is **detached→checkout · dirty→A · open-PR→E · recorded-branch-exists→B · main-behind→D · recorded-branch-missing→B(fresh) · next-up→B/D · else→C(silent)**; "(current ✓)" renders only when main drift is known `0`; lines render only when they carry signal.
- **RWC-9:** Schema completeness: `worktrees[]` entries carry `path` + `branch` only (no `dirty` field); `local_branches` lists local branch short-names; the GitHub PR lookup is bounded by `$ARBO_WORKSPACE_FETCH_TIMEOUT` (default 5s), like the fetch — no unbounded synchronous `gh` call.

## Versioning

- **1.0** (2026-05-29) — initial contract. Producer + consumer shapes as of `scripts/refresh-workspace-cache.sh` post-Task-1/2/3 and `.claude/hooks/session-start.sh` post-Task-5 on `feat/session-workspace-orientation-build`. Issue #375.
