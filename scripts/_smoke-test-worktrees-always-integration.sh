#!/usr/bin/env bash
# owner: workspace-skill
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-worktrees-always-integration.sh — End-to-end integration for the
# worktrees-always default (#716): exercises the predicate, the structural
# one-branch-per-worktree guard, the resolve round-trip, and git-based removal
# over a real worktree lifecycle. Drives the helpers (not the live harness
# EnterWorktree/ExitWorktree tools) so it runs in CI. Auto-discovered by
# ci-checks.sh's _smoke-test-* glob.
# shellcheck disable=SC1090
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WSC="$ROOT/scripts/workspace-context.sh"
WL="$ROOT/scripts/workspace-list.sh"
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

P=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$P"' EXIT
git init -q "$P/main"; cd "$P/main" || exit 1
git config user.email t@t; git config user.name t
git symbolic-ref HEAD refs/heads/main
echo seed > f; git add f; git commit -qm seed

# Create a session worktree the way /start's seam does (native .claude/worktrees/).
WT="$P/main/.claude/worktrees/feat-900-x"
git worktree add -q "$WT" -b feat/900-x >/dev/null 2>&1

# ── INT-1: the predicate flips across the create → enter lifecycle ──
( cd "$WT"      && . "$WSC" && workspace_is_session_worktree ) && pass "INT-1 predicate: linked worktree = 0" || fail_case "INT-1 linked should be 0"
( cd "$P/main" && . "$WSC" && workspace_is_session_worktree ) && fail_case "INT-1 primary should be 1 (non-zero)" || pass "INT-1 predicate: primary tree = 1"

# ── INT-2: git refuses a second worktree on the same branch (the primary guard) ──
if git worktree add -q "$P/main/.claude/worktrees/dup" feat/900-x >/dev/null 2>err; then
  fail_case "INT-2 git allowed a duplicate checkout of feat/900-x" "$(cat err 2>/dev/null)"
else
  pass "INT-2 git refuses one-branch-in-two-worktrees (structural guard)"
fi

# ── INT-3: workspace_resolve_target round-trips the created worktree ──
got="$( cd "$P/main" && . "$WL" && workspace_resolve_target feat/900-x 2>/dev/null )"
[ "$got" = "$WT" ] && pass "INT-3 resolve_target → the created worktree path" || fail_case "INT-3 resolve mismatch" "got=$got want=$WT"

# ── INT-4: git worktree remove cleans it (the /cleanup path) ──
if git -C "$P/main" worktree remove "$WT" --force >/dev/null 2>&1; then
  [ ! -d "$WT" ] && pass "INT-4 git worktree remove cleans the session worktree" || fail_case "INT-4 worktree dir survived removal"
else
  fail_case "INT-4 git worktree remove failed"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
