---
script: .claude/hooks/worktree-write-guard.sh
version: 1.0
invokers:
  - type: hook
    name: Claude PreToolUse (Write|Edit|NotebookEdit)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-19-worktree-write-guard-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `.claude/hooks/worktree-write-guard.sh`

## Surface

PreToolUse hook for the Claude Code `Write` / `Edit` / `NotebookEdit` tools.
Reads JSON from stdin (`{tool_input: {file_path | notebook_path: <path>}}`). When
the session is inside a *linked* git worktree and the target path resolves under
the **main** working tree but **not** under the **session** worktree, the hook
**denies** the tool call: it emits, on stdout, a PreToolUse
`hookSpecificOutput.permissionDecision: "deny"` whose `permissionDecisionReason`
carries a `[Worktree Guard]` message naming the corrected, worktree-rooted path,
and exits `0` (stdout JSON is processed on exit 0). Claude blocks the wrong-tree
write and re-issues it against the corrected path. Outside a linked worktree
(primary tree, non-git directory), on malformed/empty input, on a missing path
field, or when the target is correctly worktree-rooted, the hook no-ops silently
at exit `0` (no decision JSON). The hook never aborts a tool call on its own
error — a missing helper or absent `jq` degrades to a silent allow. Registered in
`.claude/settings.json` under `PreToolUse` with matcher `Write|Edit|NotebookEdit`.

## Protocol

### Arguments

The hook takes no positional arguments and no flags. It reads JSON on stdin:

```json
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "<absolute-or-relative-path>"
  }
}
```

The hook extracts the target path via
`jq -r '.tool_input.file_path // .tool_input.notebook_path // empty'` —
`file_path` for Write/Edit, `notebook_path` for NotebookEdit. Any other input
shape (non-JSON, both fields missing) causes the hook to no-op (exit 0). Relative
path values are anchored against the hook's process CWD before resolution; an
existing leaf symlink is followed (bounded) so a worktree path that symlinks into
the main tree is classified by its real target.

The hook resolves its sibling helpers relative to its own location
(`.claude/hooks/../../scripts/`): `workspace-context.sh` (for
`workspace_is_session_worktree`) and `lib/scrub-control-chars.sh` (for
`scrub_control_chars_oneline`). If either helper is absent or fails to load, the
hook degrades to a silent no-op (exit 0) rather than blocking work.

### Exit codes

- `0` — always. Either a silent no-op (not in a linked worktree, malformed input,
  missing path field, correctly worktree-rooted target, or a helper/`jq` could
  not be loaded) **or** a mis-targeted-write deny (stdout decision JSON, still
  exit 0). The deny is carried in the JSON body, not the exit code: per the
  Claude Code hooks reference, exit-0 stdout JSON is parsed (and a
  `permissionDecision: "deny"` blocks the tool), whereas exit `2` would feed
  stderr to Claude and ignore stdout. This hook deliberately uses the exit-0 +
  decision-JSON path. `1` is unused.

### Side effects

No network calls. No disk writes. Read-only git probes only
(`git rev-parse --show-toplevel`, `git worktree list --porcelain`, `readlink`,
plus the sourced `workspace-context.sh`'s read-only `git rev-parse` calls).
Stdout carries the decision JSON only on the mis-target (deny) path and is empty
otherwise. Stderr is always empty.

## Test surface

- **WG-1: Worktree gate.** The hook only acts when
  `workspace_is_session_worktree` reports a linked worktree (exit 0 of that
  predicate). A primary-tree session (predicate exit 1) and a non-git directory
  (predicate exit 2) no-op silently at exit 0.
- **WG-2: Mis-target deny.** From a linked-worktree session, when the resolved
  target path is under the main worktree root but not under the session worktree
  root, the hook emits `hookSpecificOutput.permissionDecision: "deny"` on stdout
  (exit 0) whose `permissionDecisionReason` names the corrected path (target with
  the main root prefix swapped for the session worktree root). Covers Write/Edit
  (`file_path`) and NotebookEdit (`notebook_path`).
- **WG-3: Correct-target silence.** A target resolving under the session
  worktree root produces zero output and exit 0 (no decision).
- **WG-4: Path resolution.** Relative path values are anchored against the hook
  CWD and normalized (handling `..`, `.`, deepest-existing-ancestor resolution,
  and an existing leaf symlink) before the under-root comparison, so a relative
  path or a worktree-rooted symlink that climbs into the main tree is detected.
- **WG-5: Graceful no-op on bad input.** Missing path field, non-JSON stdin, or
  empty stdin → silent no-op, exit 0.
- **WG-6: Control-char scrub.** Any path text placed in the deny reason is
  scrubbed via `scrub_control_chars_oneline`; raw control bytes (e.g. ESC
  `0x1b`) never appear in the output (CLAUDE.md § Defense in depth).
- **WG-7: Output invariant.** Stderr is always empty. Stdout is empty except for
  the decision JSON on the mis-target (deny) path. Exit code is always 0.

## Versioning

- **1.0** — initial contract (2026-06-19, #825/#826). PreToolUse guard that
  **denies** a main-tree-targeted Write/Edit/NotebookEdit from a worktree session
  (via stdout `permissionDecision: "deny"` + corrected-path reason, exit 0) and
  no-ops otherwise. Reads `file_path` and `notebook_path`; follows leaf symlinks.
  Adopter distribution (init/template/bootstrap + helper deps) tracked in #827.
