---
script: .claude/hooks/pre-commit-branch-check.sh
version: 1.2
invokers:
  - type: hook
    name: Claude PreToolUse (Bash)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-29-pipeline-overhaul-ws5-pr5-pre-commit-branch-check-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
  - docs/superpowers/specs/2026-06-09-collision-mvp-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `.claude/hooks/pre-commit-branch-check.sh`

## Surface

PreToolUse hook for the Claude Code Bash tool. Reads JSON from stdin (`{tool_input: {command: <bash-command-string>}}`), determines whether the wrapped command will invoke `git commit`, resolves the commit-target dir from explicit command operands, and blocks the commit (exit `2`, multi-line stderr message) when the resolved target's current branch is in a project-configured protected list. After the protected-branch check, it runs a **non-blocking collision read-back** (epic #622 L1, #624): when `workspace-collision-check.sh --pre-commit` returns `warn-reattach` for the target, the hook emits a `[Collision]` advisory to stderr and still exits `0` — the only blocking exit stays the protected-branch case. Layer-2+ only — silently no-ops for projects at lower layers. Invoked by the Claude harness before every Bash tool call when registered in `.claude/settings.json` PreToolUse hooks.

## Protocol

### Arguments

The hook takes no positional arguments and no flags. It reads JSON on stdin:

```json
{
  "tool_input": {
    "command": "<bash-command-string>"
  }
}
```

The hook extracts `tool_input.command` via `jq -r '.tool_input.command // empty'`. Any other input shape causes the hook to no-op (exit 0).

The hook also reads two environment variables when invoked from the Claude harness:
- `$CLAUDE_PROJECT_DIR` — the project root (used to locate `.arboretum.yml` for the layer check). Falls back to `$(pwd)` when unset.
- `$PWD` — used as the commit-target-dir fallback when neither `git -C <dir>` nor leading `cd <dir> &&` is present in the wrapped command.

### Exit codes

- `0` — permitted. One of: (a) wrapped command does not contain `git commit` substring; (b) project layer is below 2; (c) resolved commit-target dir is not a git repository or `git -C` errors for any reason; (d) resolved commit-target dir's branch is not in the protected list. A `0` exit MAY carry a non-blocking `[Collision]` advisory on stderr (see CLI-8) — the advisory never changes the exit code.
- `2` — blocked. The resolved commit-target dir is on a branch in the protected list (default `main`, `master`). Multi-line block message emitted to stderr.

No other exit codes. `1` is reserved (the hook has no argument-parsing failures to emit) — pinned in CLI-6.

### Side effects

Read-only — no disk writes and no network calls. Beyond the resolved-target branch read (`git rev-parse`), the hook may run the collision read-back (`workspace-collision-check.sh --pre-commit`, itself read-only: `git worktree list` / `git for-each-ref` and a sourced `workspace-context.sh`) when the script is present and the protected-branch check passed. Stderr output occurs on the block path (exit 2) and on the non-blocking collision-advisory path (exit 0). Pinned in CLI-7 (block path) and CLI-8 (advisory path).

## Test surface

- **CLI-1: Trigger discipline.** The hook fires when the wrapped Bash command string matches `git\s+(-C\s+\S+\s+)?commit([^a-zA-Z0-9_-]|$)` — `git` followed by `commit`, with an optional `-C <dir>` operand between them, and a trailing boundary that accepts any non-word-continuation character (whitespace, `;`, `|`, `)`, `&`, `<`, `>`, etc.) or end-of-string. The boundary excludes `[a-zA-Z0-9_-]` so `git commit-tree` and similar subcommands do not match. Non-commit commands (`git status`, `git log --oneline`, unrelated commands) exit 0 with no output.
- **CLI-2: Layer gate.** When `$CLAUDE_PROJECT_DIR/.arboretum.yml` declares `layer: 0` or `layer: 1`, or when `.arboretum.yml` is missing entirely, the hook exits 0 with no output. The hook is Layer-2+ only.
- **CLI-3: Commit-target resolution.** Given a wrapped command string containing `git commit`, the commit-target dir is resolved in priority order: (1) the operand of the first `git -C <dir>` match within the same `&&`/`;`/`|`/`()`-delimited chunk as `commit`, if present; (2) the operand of a leading `cd <dir> &&` match if the command is shaped that way from the start; (3) `$PWD` as fallback. A single leading or trailing single-or-double quote on either operand is stripped before use (`git -C '/repo'` / `cd "/repo" &&` resolve to `/repo`). When `GIT_C_TARGET` is relative, it is anchored against `CD_TARGET` (if present) else `$PWD` — so `cd /base && git -C repo commit` resolves to `/base/repo`. The branch check uses `git -C <resolved-dir> rev-parse --abbrev-ref HEAD` — never the unconditional process-CWD form pre-PR-5 used. Edge cases (subshell `(cd /p && ...)`, semicolon `cd /p; ...`, pipes) fall through to `$PWD` per design D1; tracked as a known limitation in the project issue tracker (see related-designs).
- **CLI-4: Cross-repo non-firing.** When the resolved commit-target dir is a git repository whose branch is NOT in the protected list, the hook exits 0 with no output. When the resolved commit-target dir is not a git repository at all, or when `git -C` errors for any reason, the hook ALSO exits 0 with no output. **Closes #139 as non-recurrable.**
- **CLI-5: Protected-branch blocking.** When the resolved commit-target dir's branch is in the protected list, the hook exits 2 and emits the three-line block message to stderr: `[Branch Protection] Cannot commit to '<branch>'.` / `  → Why: All work happens on feature branches for clean history and PR-based review.` / `    Run: git checkout -b feat/your-feature.`. Preserves the original protection contract.
- **CLI-6: Exit-code contract.** The hook exits with one of two codes: `0` (permitted) or `2` (blocked). No other exit codes — `1` is explicitly reserved and never emitted.
- **CLI-7: No-side-effect invariant.** All paths produce zero stdout. The block path produces only stderr (exit 2). Permitted paths produce zero stderr EXCEPT the non-blocking collision advisory (CLI-8). The hook performs no disk writes and no network calls; beyond the `git rev-parse` branch read it may spawn the read-only collision read-back.
- **CLI-8: Collision advisory (non-blocking).** After the protected-branch check passes, when `workspace-collision-check.sh` is present (resolved relative to the hook at `../../scripts/`) and `--pre-commit` returns `VERDICT=warn-reattach` for the commit target, the hook emits a two-line `[Collision] …` advisory to stderr and exits `0` — the commit is permitted. A `clear` verdict, a missing script, or a non-git target produces no advisory. The advisory never escalates to a block; the sole exit-2 path remains the protected-branch case (D6). Stdout stays empty.

## Versioning

- **1.0** — initial contract (2026-05-29). Ships with the #139 fix that introduces the commit-target-resolution chain (D1 of the related design spec).
- **1.1** — round-1 /land review (PR #372, 2026-05-29). Widens CLI-1 trigger boundary to accept shell delimiters (`;`, `|`, `)`, `&`) after `commit` — `git commit; echo done` was no-op'd by the 1.0 boundary, a regression vs the pre-PR-5 substring match. Extends CLI-3 with quote-stripping (`git -C '/repo'` and `cd "/repo" &&` shapes) and relative-target anchoring (`cd /base && git -C repo commit` → `/base/repo`). Both gaps were silent bypasses on host-feat / target-main combinations. Smoke surface extended to CLI-1 + CLI-3 + CLI-4 scenarios J/K/L/M.
- **1.2** — collision MVP (#624, epic #622 L1, 2026-06-09). Adds the non-blocking collision read-back (CLI-8): after the protected-branch check, a `warn-reattach` verdict from `workspace-collision-check.sh --pre-commit` emits a `[Collision]` advisory to stderr at exit 0. Amends CLI-7 (permitted paths may now carry the advisory on stderr) and the side-effects note (one additional read-only subprocess). Exit-code contract (CLI-6) unchanged — the advisory is exit 0, the sole block stays protected-branch. Smoke surface extended with scenario N.
