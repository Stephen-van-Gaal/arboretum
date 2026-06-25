#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# PreToolUse hook for Write/Edit/NotebookEdit: block when a worktree session
# targets the MAIN-tree path instead of the session worktree (#825, #826).
#
# During a worktree session it is easy to construct a main-tree absolute path
# (skill bodies use repo-relative paths; harness Write/Edit/NotebookEdit take
# absolute ones) and write to the wrong tree. This hook detects that and returns
# a PreToolUse `permissionDecision: deny` whose reason names the corrected,
# worktree-rooted path — so Claude blocks the wrong-tree write and self-corrects.
#
# Convention: DENY + corrected-path reason (design D1, #825/#826). A bare stderr
# advisory at exit 0 is invisible to Claude — per the Claude Code hooks reference,
# stdout JSON is parsed on exit 0 while stderr reaches Claude only on exit 2, so a
# non-blocking "warn" cannot actually surface to the agent without a
# permissionDecision. `deny` is the only path that both prevents the mis-targeted
# write and feeds the corrected path back. The deny JSON is emitted on STDOUT and
# the hook exits 0 (JSON is processed on exit 0).
#
# Defense-in-depth: any path text echoed into Claude's context is scrubbed with
# the shared control-char primitive (CLAUDE.md § Defense in depth).
#
# No-ops gracefully (exit 0, silent, no decision) when: input is malformed / has
# no path; the session is not inside a linked worktree (primary tree, or not a
# git work tree); or the target resolves under the session worktree (the correct
# case). The hook only ever blocks the specific mis-targeted-write case and never
# aborts on its own error (a missing helper degrades to a silent allow).

set -uo pipefail

INPUT=$(cat 2>/dev/null || printf '')

# Extract the target path. Write/Edit use tool_input.file_path; NotebookEdit uses
# tool_input.notebook_path — fall through to it so notebook edits are guarded too
# (the PreToolUse matcher includes NotebookEdit; #826 P2). Any non-JSON /
# missing-field input no-ops at exit 0 (the `2>/dev/null || echo ''` guards jq's
# parse-error code under pipefail — same pattern as pre-commit-branch-check.sh).
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo '')
[ -n "$FILE_PATH" ] || exit 0

# Resolve the hook's lib/script locations relative to THIS file so it works from
# any session cwd (incl. cross-tree). worktree-write-guard.sh lives in
# .claude/hooks/, so scripts/ is ../../scripts.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSC="$HOOK_DIR/../../scripts/workspace-context.sh"
SCRUB="$HOOK_DIR/../../scripts/lib/scrub-control-chars.sh"

# Only act inside a *linked* worktree. Source workspace-context.sh in a way that
# can't abort this hook, then consult its authoritative predicate. If the helper
# is missing or fails to load, no-op (exit 0) — the guard degrades safely rather
# than blocking work.
# shellcheck source=/dev/null
[ -f "$WSC" ] && . "$WSC" 2>/dev/null || exit 0
command -v workspace_is_session_worktree >/dev/null 2>&1 || exit 0

# 0 = linked session worktree; 1 = primary tree; 2 = not a git work tree.
# Only a linked worktree session can mis-target the main tree, so anything else
# no-ops silently.
workspace_is_session_worktree || exit 0

# Session worktree root (the tree we are correctly working in).
SESSION_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
[ -n "$SESSION_ROOT" ] || exit 0

# Main worktree root = the FIRST `worktree ` line of `git worktree list
# --porcelain`; git always lists the primary working tree first.
MAIN_ROOT="$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{print substr($0,10); exit}')"
[ -n "$MAIN_ROOT" ] || exit 0

# Canonicalize all three to absolute physical paths so prefix comparison is
# robust across cwd, relative inputs, and macOS /var -> /private/var symlinks.
abspath() { # <path> ; echoes a normalized absolute path (best-effort, no realpath dep)
  local p="$1" tail="" hops=0
  case "$p" in
    /*) : ;;                 # already absolute
    *)  p="$PWD/$p" ;;       # anchor relative paths against the hook's cwd
  esac
  # Follow an existing LEAF symlink chain (bounded) FIRST: a worktree path that is
  # itself a symlink into the main tree must be classified by its real target —
  # otherwise a write through it silently mutates the main tree (Codex P3, #826).
  # readlink's one-hop form is portable across GNU + BSD; cap the chain so a
  # symlink loop can't spin forever.
  while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
    local link; link="$(readlink "$p" 2>/dev/null)" || break
    case "$link" in
      /*) p="$link" ;;                 # absolute symlink target
      *)  p="$(dirname "$p")/$link" ;; # relative to the link's own directory
    esac
    hops=$((hops + 1))
  done
  # Walk up to the deepest EXISTING ancestor directory and resolve it physically
  # (this normalizes `..`, `.`, and symlinks even when the leaf path — a
  # not-yet-created target file or its parent dirs — does not exist yet).
  while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do
    tail="/$(basename "$p")$tail"
    p="$(dirname "$p")"
  done
  if cd "$p" 2>/dev/null; then
    printf '%s%s' "$(pwd -P)" "$tail"
  else
    printf '%s%s' "$p" "$tail"   # nothing resolvable: lexical join (best-effort)
  fi
}

# Resolve in subshells so the cd inside abspath never leaks into the hook's cwd.
TARGET_ABS="$(abspath "$FILE_PATH")"
SESSION_ROOT="$( cd "$SESSION_ROOT" 2>/dev/null && pwd -P || printf '%s' "$SESSION_ROOT" )"
MAIN_ROOT="$( cd "$MAIN_ROOT" 2>/dev/null && pwd -P || printf '%s' "$MAIN_ROOT" )"

# If session and main resolve to the same root, there is nothing to guard.
[ "$SESSION_ROOT" != "$MAIN_ROOT" ] || exit 0

# under <root> <path> : true when <path> is <root> itself or a child of it.
under() { local root="$1" p="$2"; [ "$p" = "$root" ] || case "$p" in "$root"/*) return 0;; esac; return 1; }

# Mis-targeted iff the write lands under the MAIN root but NOT under the SESSION
# root. Otherwise (under the session root, or under neither) allow silently.
if under "$MAIN_ROOT" "$TARGET_ABS" && ! under "$SESSION_ROOT" "$TARGET_ABS"; then
  # Corrected hint: swap the main root prefix for the session root.
  suffix="${TARGET_ABS#"$MAIN_ROOT"}"          # leading-slash-prefixed remainder
  corrected="${SESSION_ROOT}${suffix}"
  # Scrub the path text before it enters Claude's context (defense-in-depth).
  safe_target="$TARGET_ABS"; safe_corrected="$corrected"
  # shellcheck source=/dev/null
  if [ -f "$SCRUB" ] && . "$SCRUB" 2>/dev/null \
     && command -v scrub_control_chars_oneline >/dev/null 2>&1; then
    safe_target="$(printf '%s' "$TARGET_ABS" | scrub_control_chars_oneline)"
    safe_corrected="$(printf '%s' "$corrected" | scrub_control_chars_oneline)"
  fi
  reason="[Worktree Guard] This targets the MAIN tree, not the session worktree: ${safe_target}. Use the worktree path instead: ${safe_corrected}"
  # Emit a PreToolUse deny on STDOUT (parsed on exit 0). deny is the only outcome
  # that both blocks the wrong-tree write and feeds the corrected path back so
  # Claude self-corrects (design D1; verified against the Claude Code hooks
  # reference). jq -n --arg handles JSON escaping of the (already scrubbed) text.
  # If jq is somehow unavailable here, degrade to a silent allow rather than
  # emitting malformed JSON.
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
fi

exit 0
