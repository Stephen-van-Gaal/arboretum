#!/usr/bin/env bash
# owner: workspace-skill
# _smoke-test-contract-workspace-list.sh - Contract test for
# docs/contracts/workspace-list.contract.md (seam: workspace-skill).
# Drives the sourced helper over a git fixture with multiple worktrees.
# shellcheck disable=SC1090  # $LIB is resolved at runtime; sourcing it dynamically is intentional.
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/workspace-list.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

FIX=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# Primary tree on main + two linked worktrees on feat/716-x and feat/701-y.
git init -q "$FIX/work"
cd "$FIX/work" || exit 1
git config user.email t@t; git config user.name t
git symbolic-ref HEAD refs/heads/main
echo seed > f; git add f; git commit -qm seed
git worktree add -q "$FIX/wt716" -b feat/716-x >/dev/null 2>&1
git worktree add -q "$FIX/wt701" -b feat/701-y >/dev/null 2>&1

# Seed the cache with an open_pr for the current branch (main here). The PR title
# is author-controlled (from `gh`); embed a JSON-escaped ESC () — valid JSON
# on disk, but a raw control byte once rendered. The helper must re-scrub it at the
# render seam (defense-in-depth: scrub at cache-write AND consumer, per CLAUDE.md).
mkdir -p "$FIX/work/.arboretum"
cat > "$FIX/work/.arboretum/workspace-cache.json" <<'JSON'
{ "current_branch": "main", "open_pr": {"number": 42, "title": "ev\u001bil", "state": "OPEN"}, "worktrees": [] }
JSON

# ---- WL-1: workspace_list_json — one entry per worktree, current marked, scrubbed ----
out="$( cd "$FIX/work" && . "$LIB" && workspace_list_json )"
n=$(printf '%s' "$out" | jq 'length' 2>/dev/null)
cur=$(printf '%s' "$out" | jq -r '[.[] | select(.current==true)] | length' 2>/dev/null)
{ [ "$n" -ge 3 ] && [ "$cur" = 1 ]; } \
  && pass "WL-1 list: $n worktrees, exactly one current" \
  || fail_case "WL-1 list shape wrong" "n=$n current=$cur out=$out"
# The PR title must come back scrubbed (no raw ESC byte), and equal "evil".
title="$( printf '%s' "$out" | jq -r '[.[] | select(.current==true) | .open_pr.title] | .[0] // ""' )"
case "$title" in *$'\x1b'*) fail_case "WL-1 scrub: ESC survived in PR title" "title=[$title]";; *) pass "WL-1 PR title control char scrubbed (render-side)";; esac
[ "$title" = "evil" ] && pass "WL-1 PR title intact after scrub" || fail_case "WL-1 PR title wrong" "got=[$title]"
# issue parsed from feat/<N>-… branch
iss=$(printf '%s' "$out" | jq -r '[.[] | select(.branch=="feat/716-x") | .issue] | .[0]' 2>/dev/null)
[ "$iss" = "716" ] && pass "WL-1 issue parsed from branch" || fail_case "WL-1 issue parse" "got=$iss"

# ---- WL-2: workspace_resolve_target — issue/branch/path → one path; no/ambiguous → exit 1 ----
p_iss="$( cd "$FIX/work" && . "$LIB" && workspace_resolve_target 716 2>/dev/null )"
[ "$p_iss" = "$FIX/wt716" ] && pass "WL-2 resolve by issue" || fail_case "WL-2 resolve by issue" "got=$p_iss"
p_br="$( cd "$FIX/work" && . "$LIB" && workspace_resolve_target feat/701-y 2>/dev/null )"
[ "$p_br" = "$FIX/wt701" ] && pass "WL-2 resolve by branch" || fail_case "WL-2 resolve by branch" "got=$p_br"
if ( cd "$FIX/work" && . "$LIB" && workspace_resolve_target nonesuch ) >/dev/null 2>&1; then
  fail_case "WL-2 no-match should exit 1"
else
  pass "WL-2 no-match exits 1"
fi

# ---- WL-3: zsh portability — list emits valid JSON under the user's shell ----
# The /workspace skill runs in the user's zsh shell. A `local` inside the piped
# while-subshell leaks `name=value` lines to stdout under zsh and corrupts the
# JSON stream (#716). Guard on zsh being installed so bash-only CI stays green.
if command -v zsh >/dev/null 2>&1; then
  zn="$(WL_LIB="$LIB" WL_DIR="$FIX/work" zsh -c '
    cd "$WL_DIR" || exit 1
    source "$WL_LIB" 2>/dev/null || { printf SRC-FAIL; exit 0; }
    workspace_list_json 2>/dev/null | jq "length" 2>/dev/null')"
  { [ -n "$zn" ] && [ "$zn" -ge 3 ] 2>/dev/null; } \
    && pass "WL-3 zsh: list emits valid JSON ($zn worktrees)" \
    || fail_case "WL-3 zsh sourcing/list broken" "got=[$zn]"
else
  echo "SKIP: WL-3 — zsh not installed"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
