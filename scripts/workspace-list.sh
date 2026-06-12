#!/usr/bin/env bash
# owner: workspace-skill
# workspace-list.sh - Enumerate + enrich the repo's worktrees, and resolve a
# switch selector to a worktree path. Sourced, never executed. The data half of
# the /workspace skill (list + switch); creation is owned by the /start seam.
# Source of truth = `git worktree list --porcelain`; enrichment = the workspace
# cache (best-effort). All author-controlled strings are control-char-scrubbed.
# See docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md.

# Source workspace-context.sh (loads the scrub primitive + provides
# workspace_tree_root / workspace_cache_path), worktree-correctly relative to
# THIS file. Portable self-resolution: bash populates BASH_SOURCE; zsh uses %x.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_WSL_SELF="${(%):-%x}"'
else
  _WSL_SELF="${BASH_SOURCE[0]:-$0}"
fi
_WSL_DIR="$(cd "$(dirname "$_WSL_SELF")" && pwd)"
# Fail CLOSED: without workspace-context (hence without scrub), author-controlled
# branch names would flow unscrubbed. Refuse to define the API.
# shellcheck source=/dev/null
. "$_WSL_DIR/workspace-context.sh" 2>/dev/null || {
  printf 'workspace-list: FATAL: cannot source %s/workspace-context.sh\n' "${_WSL_DIR:-?}" >&2
  return 1 2>/dev/null || exit 1
}

# workspace_list_json — emit a JSON array of the repo's worktrees, enriched.
# Per entry: { path, branch, current, dirty, issue, open_pr }.
#   current  — path == workspace_tree_root (the invoking session's worktree)
#   dirty    — `git status --porcelain` non-empty in that worktree
#   issue    — parsed from a feat/<N>-… (or fix/<N>-…) branch; null otherwise
#   open_pr  — from the cache's open_pr, but only for the cache's current_branch
#              (the cache only carries open_pr for the current branch); null else
# branch is scrubbed (git permits control bytes in ref names).
workspace_list_json() {
  local here cache cache_cur cache_pr
  here="$(workspace_tree_root)"
  cache="$(workspace_cache_path)"
  cache_cur=""; cache_pr="null"
  if [ -f "$cache" ]; then
    cache_cur="$(jq -r '.current_branch // ""' "$cache" 2>/dev/null)"
    cache_pr="$(jq -c '.open_pr // null' "$cache" 2>/dev/null)"; [ -n "$cache_pr" ] || cache_pr="null"
  fi
  # NB: the while loop below runs in its own subshell (it is the middle stage of a
  # pipe), so loop-local vars do not leak to the function scope and need no `local`.
  # Critically, under zsh `local` *inside* this pipe-subshell prints each
  # `name=value` declaration to STDOUT, which would corrupt the JSON stream the
  # final `jq -s` slurps (#716). Plain assignments are correct and portable here.
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' | while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    br="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null | scrub_control_chars)"
    dirty=false; [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty=true
    issue="$(printf '%s' "$br" | sed -nE 's@^(feat|fix|chore|docs)/([0-9]+)-.*@\2@p')"
    if [ -n "$issue" ]; then issue_json="$issue"; else issue_json="null"; fi
    cur=false; [ "$wt" = "$here" ] && cur=true
    prj="null"
    if [ -n "$cache_cur" ] && [ "$br" = "$cache_cur" ] && [ "$cache_pr" != "null" ]; then
      # Re-scrub the author-controlled PR title at the render seam (defense in
      # depth): a hand-edited or older cache may carry a \u-escaped control char
      # that is valid JSON on disk but renders raw into Claude's context.
      _t="$(printf '%s' "$cache_pr" | jq -r '.title // ""' | scrub_control_chars)"
      prj="$(printf '%s' "$cache_pr" | jq -c --arg t "$_t" '.title = $t')"
    fi
    jq -nc --arg path "$wt" --arg branch "$br" \
      --argjson current "$cur" --argjson dirty "$dirty" \
      --argjson issue "$issue_json" --argjson open_pr "$prj" \
      '{path:$path, branch:$branch, current:$current, dirty:$dirty, issue:$issue, open_pr:$open_pr}'
  done | jq -s '.'
}

# workspace_resolve_target <selector> — selector is a worktree path, a branch
# name, or an issue number. Echo the single matching worktree path; exit 1 with a
# stderr message on no match or ambiguity. Used by /workspace switch.
workspace_resolve_target() {
  local sel="${1:-}" list matches
  [ -n "$sel" ] || { echo "workspace_resolve_target: no selector given" >&2; return 1; }
  list="$(workspace_list_json)" || { echo "workspace_resolve_target: cannot enumerate worktrees" >&2; return 1; }
  # Precedence: exact path → exact branch → issue number. First tier with any
  # match wins; >1 match within the winning tier is ambiguous.
  matches="$(printf '%s' "$list" | jq -r --arg s "$sel" '.[] | select(.path==$s) | .path')"
  [ -z "$matches" ] && matches="$(printf '%s' "$list" | jq -r --arg s "$sel" '.[] | select(.branch==$s) | .path')"
  [ -z "$matches" ] && matches="$(printf '%s' "$list" | jq -r --arg s "$sel" '.[] | select(.issue != null and (.issue|tostring)==$s) | .path')"
  local count; count="$(printf '%s\n' "$matches" | grep -c . )"
  if [ "$count" -eq 0 ]; then
    echo "workspace_resolve_target: no worktree matches '$sel'" >&2; return 1
  elif [ "$count" -gt 1 ]; then
    echo "workspace_resolve_target: '$sel' is ambiguous ($count matches)" >&2; return 1
  fi
  printf '%s\n' "$matches"
}
