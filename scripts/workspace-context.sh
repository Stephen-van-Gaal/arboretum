#!/usr/bin/env bash
# owner: workspace-context
# scope: plugin-only
# workspace-context.sh - Single tree-root + base + branch resolver.
# Sourced, never executed. Source-time effects are limited to defining functions
# and loading the scrub primitive (which exports ARBO_CTRL_CHAR_CLASS); it runs no
# git and mutates no repo until a function is called. Reuses
# refresh-workspace-cache.sh patterns (remote resolution, control-char scrub)
# rather than rebuilding signal-gathering. See
# docs/superpowers/specs/2026-06-07-workspace-context-helper-design.md.

# Source the canonical scrub primitive (#634, owner: shared-components),
# worktree-correctly relative to THIS file. Resolve this file's own path
# portably: bash populates BASH_SOURCE; zsh leaves it empty and sets $0 to the
# sourced file instead. Consumers source this from SKILL.md blocks that run in
# the user's shell (zsh), so bash-only ${BASH_SOURCE[0]} is not enough.
# bash populates BASH_SOURCE; zsh uses %x prompt expansion (the file being sourced)
# which, unlike $0, is correct even when zsh's FUNCTION_ARGZERO option is off.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_WSC_SELF="${(%):-%x}"'
else
  _WSC_SELF="${BASH_SOURCE[0]:-$0}"
fi
_WSC_LIB_DIR="$(cd "$(dirname "$_WSC_SELF")/lib" && pwd)"
# Fail CLOSED: if the scrub primitive can't load, author-controlled strings would
# flow into Claude's context unscrubbed (or getters would silently emit empty).
# Refuse to define the API rather than degrade the security guarantee silently.
# shellcheck source=/dev/null
. "$_WSC_LIB_DIR/scrub-control-chars.sh" 2>/dev/null || {
  printf 'workspace-context: FATAL: cannot load %s/scrub-control-chars.sh\n' "${_WSC_LIB_DIR:-?}" >&2
  return 1 2>/dev/null || exit 1
}
command -v scrub_control_chars >/dev/null 2>&1 || {
  printf 'workspace-context: FATAL: scrub_control_chars undefined after sourcing the scrub primitive\n' >&2
  return 1 2>/dev/null || exit 1
}

# Remote: origin-preferred, else first remote (mirrors refresh-workspace-cache.sh).
# Scrub the output: a remote name is author-controlled (git permits C1 bytes like
# 0x9b in it) and flows into ARBO_REMOTE / Claude's context.
workspace_remote() {
  { if git remote 2>/dev/null | grep -qx origin; then printf 'origin'
    else git remote 2>/dev/null | head -n1; fi; } | scrub_control_chars
}

workspace_tree_root() { git rev-parse --show-toplevel 2>/dev/null | scrub_control_chars; }

# Current branch short name; empty on detached HEAD.
workspace_branch() { git symbolic-ref --quiet --short HEAD 2>/dev/null | scrub_control_chars; }

# Is the current invocation inside a *linked* (session) worktree, as opposed to
# the primary tree? Authoritative via git's own registration: a linked worktree's
# --git-dir lives under <main>/.git/worktrees/<name> while --git-common-dir points
# at the shared <main>/.git; in the primary tree the two resolve to the same path.
# No stdout (a predicate, not a getter), so nothing author-controlled to scrub.
# Exit: 0 = linked session worktree, 1 = primary tree, 2 = not in a git work tree.
workspace_is_session_worktree() {
  local gd cd
  # A bare repo (or being inside a .git dir) has no work tree → 2, per contract.
  # Without this, a bare repo's --git-dir and --git-common-dir compare equal and
  # would misreport as the primary tree (exit 1). (B4 correctness finding, #716.)
  [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || return 2
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 2
  cd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 2
  [ -n "$gd" ] && [ -n "$cd" ] || return 2
  # --git-common-dir may be relative (".git") or absolute; canonicalize both to
  # absolute physical paths so the comparison is robust across cwd and macOS symlinks.
  cd="$(cd "$cd" 2>/dev/null && pwd -P)" || return 2
  gd="$(cd "$(dirname "$gd")" 2>/dev/null && pwd -P)/$(basename "$gd")" || return 2
  [ "$gd" != "$cd" ]   # differ ⇒ linked (exit 0); equal ⇒ primary (exit 1)
}

# Handle to the workspace cache (the file may not exist; we neither create nor refresh it).
workspace_cache_path() { printf '%s/.arboretum/workspace-cache.json' "$(workspace_tree_root)"; }

# Internal: resolve the default-branch SHORT name + its classification with NO
# command substitution, so a direct caller (notably workspace_context) observes
# the side-effect vars in its own scope. Sets _WSC_DEFAULT (scrubbed short name)
# and ARBO_BASE_SOURCE. Probe order: origin/HEAD -> origin/main -> origin/master
# -> local. Read-only — never `git remote set-head`.
_workspace_resolve_default() {
  local remote head; remote="$(workspace_remote)"
  if [ -n "$remote" ]; then
    head="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null)"
    # Accept origin/HEAD only if its target still resolves to a commit; a stale
    # HEAD (e.g. default branch renamed/deleted) must fall through to main/master.
    if [ -n "$head" ] && git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
      ARBO_BASE_SOURCE="remote-head"
      _WSC_DEFAULT="$(printf '%s' "${head#refs/remotes/$remote/}" | scrub_control_chars)"
      return 0
    fi
    if git rev-parse --verify --quiet "refs/remotes/$remote/main" >/dev/null; then
      ARBO_BASE_SOURCE="remote-main"; _WSC_DEFAULT=main; return 0
    fi
    if git rev-parse --verify --quiet "refs/remotes/$remote/master" >/dev/null; then
      ARBO_BASE_SOURCE="remote-master"; _WSC_DEFAULT=master; return 0
    fi
  fi
  ARBO_BASE_SOURCE="local-fallback"; _WSC_DEFAULT=main; return 0
}

# Default branch SHORT name (getter for $(...) use; echoes exactly one value).
# The source classification is a workspace_context output, not a getter output —
# locals here keep the global ARBO_BASE_SOURCE untouched by a getter call.
workspace_default_branch() {
  local _WSC_DEFAULT ARBO_BASE_SOURCE
  _workspace_resolve_default
  printf '%s' "$_WSC_DEFAULT"
}

# Remote-tracking base ref <remote>/<default> for diff/log/merge-base (getter;
# echoes exactly one value). --fetch opts into a bounded best-effort fetch (never
# hard-fails the caller). Warns on stderr when only a local base exists (#381).
workspace_base_ref() {
  local do_fetch=0; [ "${1:-}" = "--fetch" ] && do_fetch=1
  local remote _WSC_DEFAULT ARBO_BASE_SOURCE
  remote="$(workspace_remote)"
  _workspace_resolve_default            # sets _WSC_DEFAULT + ARBO_BASE_SOURCE (local here)
  if [ "$do_fetch" -eq 1 ] && [ -n "$remote" ]; then
    # Bounded best-effort fetch. Branch on the timeout binary explicitly rather
    # than building a "$cmd $args" string — zsh does not word-split unquoted
    # parameters, so a "timeout 5" string would be run as one command name.
    local secs="${ARBO_WORKSPACE_FETCH_TIMEOUT:-5}" ok=0
    if command -v timeout >/dev/null 2>&1; then
      timeout "$secs" git fetch "$remote" "$_WSC_DEFAULT" >/dev/null 2>&1 && ok=1
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout "$secs" git fetch "$remote" "$_WSC_DEFAULT" >/dev/null 2>&1 && ok=1
    else
      git fetch "$remote" "$_WSC_DEFAULT" >/dev/null 2>&1 && ok=1
    fi
    if [ "$ok" -ne 1 ]; then
      printf 'workspace-context: --fetch of %s/%s failed or timed out; using last-known remote-tracking ref\n' "$remote" "$_WSC_DEFAULT" >&2
    fi
    # Re-resolve after fetching: a fetch that created the tracking ref must
    # upgrade a pre-fetch local-fallback to the now-present remote base (the
    # exact recovery case --fetch exists for).
    _workspace_resolve_default
  fi
  if [ "$ARBO_BASE_SOURCE" = "local-fallback" ] || [ -z "$remote" ]; then
    printf 'workspace-context: base resolves to LOCAL ref "%s" — no remote-tracking base found; diffs may be stale (#381 risk)\n' "$_WSC_DEFAULT" >&2
    printf '%s' "$_WSC_DEFAULT" | scrub_control_chars
  else
    printf '%s/%s' "$remote" "$_WSC_DEFAULT" | scrub_control_chars
  fi
}

# Master resolver: sets ARBO_* in the caller's shell. Passes --fetch through.
# Returns non-zero with empty vars when not inside a git work tree.
workspace_context() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'workspace-context: not inside a git work tree\n' >&2
    ARBO_TREE_ROOT=""; ARBO_BRANCH=""; ARBO_DEFAULT_BRANCH=""; ARBO_BASE_REF=""
    ARBO_BASE_SOURCE=""; ARBO_REMOTE=""; ARBO_WORKSPACE_CACHE=""
    return 1
  fi
  local _WSC_DEFAULT
  ARBO_TREE_ROOT="$(workspace_tree_root)"
  ARBO_BRANCH="$(workspace_branch)"
  ARBO_REMOTE="$(workspace_remote)"
  ARBO_BASE_REF="$(workspace_base_ref "$@")"    # echoes the ref; passes --fetch through (may update tracking refs)
  _workspace_resolve_default                    # resolve AFTER any --fetch so source + default match the ref
  ARBO_DEFAULT_BRANCH="$_WSC_DEFAULT"
  ARBO_WORKSPACE_CACHE="$(workspace_cache_path)"
  export ARBO_TREE_ROOT ARBO_BRANCH ARBO_REMOTE ARBO_DEFAULT_BRANCH \
         ARBO_BASE_REF ARBO_BASE_SOURCE ARBO_WORKSPACE_CACHE
}
