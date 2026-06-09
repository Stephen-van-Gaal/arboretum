#!/usr/bin/env bash
# owner: collision-detection
# workspace-collision-check.sh — Compute a branch/worktree collision verdict.
#   --issue N     rich (network-permitted): recorded claim + on-disk detectors
#   --pre-commit  narrow (local-only): >=2 on-disk branches for the same issue
# Output: stdout `VERDICT=clear|warn-reattach|block`; stderr human reason.
# Exit:   0 = verdict computed (incl. block); >=1 = operational error.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "workspace-collision-check.sh requires bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workspace-context.sh
if ! source "$SCRIPT_DIR/workspace-context.sh"; then
  echo "workspace-collision-check: cannot source workspace-context.sh" >&2
  exit 2
fi

emit() {  # emit <verdict> [reason]
  printf 'VERDICT=%s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$(scrub_control_chars_oneline <<<"$2")" >&2
  return 0
}

MODE=""; ISSUE=""
case "${1:-}" in
  --issue)      MODE=issue; ISSUE="${2:-}";;
  --pre-commit) MODE=pre-commit;;
  *) echo "usage: workspace-collision-check.sh (--issue N | --pre-commit)" >&2; exit 1;;
esac
if [ "$MODE" = issue ] && ! printf '%s' "$ISSUE" | grep -qE '^[1-9][0-9]*$'; then
  echo "workspace-collision-check: --issue requires a positive integer" >&2; exit 1
fi

# Resolve ARBO_* for the current worktree (fails closed outside a work tree).
workspace_context || { echo "workspace-collision-check: not inside a git work tree" >&2; exit 2; }

# Map a branch name to its issue number via the leading-digit convention
# (feat/624-foo -> 624). Local + cheap; matches the worktree-naming rule.
branch_issue() {
  local slug="${1#*/}"; slug="${slug%-build}"
  printf '%s' "$slug" | grep -oE '^[0-9]+' || true
}

# Branches checked out in *worktrees* (porcelain `branch refs/heads/<name>`).
worktree_branches() {
  git worktree list --porcelain 2>/dev/null \
    | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
}

# All local branch short-names.
local_branches() { git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; }

# Latest recorded claim (branch: <name>) for the issue, from the fixture JSON
# when ARBO_COLLISION_ISSUE_JSON is set, else from the live tracker. Network
# only on the live path; never reached from --pre-commit.
recorded_claim() {
  local n="$1" json
  if [ -n "${ARBO_COLLISION_ISSUE_JSON:-}" ]; then
    json="$(cat "$ARBO_COLLISION_ISSUE_JSON" 2>/dev/null || echo '{}')"
  else
    # shellcheck source=roadmap/lib.sh
    source "$SCRIPT_DIR/roadmap/lib.sh"
    json="$(roadmap_tracker_issue_show "$n" --json number,title,state,comments 2>/dev/null || echo '{}')"
  fi
  printf '%s' "$json" | python3 -c '
import json,sys,re
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
claim=""
for c in d.get("comments",[]) or []:
    for m in re.finditer(r"(?m)^- .*— /start (?:exited|entered).*?branch:\s*([^\s,]+)", c.get("body","") or ""):
        claim=m.group(1)
print(claim)
' 2>/dev/null || true
}

if [ "$MODE" = issue ]; then
  # Exclude the caller's OWN branch from every signal: "block" means checked out
  # in ANOTHER worktree, and a claim/branch equal to the current branch is not a
  # collision (it's the continue-work case — you're already on the issue's branch).
  claim="$(recorded_claim "$ISSUE")"
  [ "$claim" = "$ARBO_BRANCH" ] && claim=""
  # On-disk branches mapping to this issue, other than the current branch.
  checked_out=""; exists_local=""
  while IFS= read -r b; do [ -n "$b" ] || continue
    [ "$(branch_issue "$b")" = "$ISSUE" ] && [ "$b" != "$ARBO_BRANCH" ] && checked_out="$b"
  done < <(worktree_branches)
  while IFS= read -r b; do [ -n "$b" ] || continue
    [ "$(branch_issue "$b")" = "$ISSUE" ] && [ "$b" != "$ARBO_BRANCH" ] && exists_local="$b"
  done < <(local_branches)

  if [ -n "$checked_out" ]; then
    emit block "issue #$ISSUE branch '$checked_out' is checked out in another worktree — reattach there (git refuses a duplicate checkout)"
    exit 0
  fi
  if [ -n "$claim" ] || [ -n "$exists_local" ]; then
    emit warn-reattach "issue #$ISSUE already has an in-flight branch (${claim:-$exists_local}) — reattach instead of forking a second branch"
    exit 0
  fi
  emit clear ""
  exit 0
fi

if [ "$MODE" = pre-commit ]; then
  # Resolve the issue from the CURRENT branch (local; no network).
  cur="$ARBO_BRANCH"
  n="$(branch_issue "$cur")"
  if [ -z "$n" ]; then emit clear ""; exit 0; fi   # branch carries no issue number

  # Count DISTINCT on-disk branches (worktree-checked-out + local) mapping to n.
  matches="$( { worktree_branches; local_branches; } | sort -u | while IFS= read -r b; do
      [ -n "$b" ] && [ "$(branch_issue "$b")" = "$n" ] && printf '%s\n' "$b"
    done | wc -l | tr -d ' ' )"

  if [ "${matches:-0}" -ge 2 ]; then
    emit warn-reattach "issue #$n has $matches local branches; you're committing on '$cur' — forking a second branch for one issue?"
  else
    emit clear ""
  fi
  exit 0
fi

# Unreachable — modes are exhaustively handled above.
emit clear ""
exit 0
