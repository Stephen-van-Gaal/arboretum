#!/usr/bin/env bash
# owner: collision-detection
# Unit smoke for scripts/workspace-collision-check.sh — verdict mapping.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/workspace-collision-check.sh"
[ -f "$SUT" ] || { echo "FAIL: $SUT not found" >&2; exit 1; }
GIT_ID=(-c user.email=t@t -c user.name=t)
fail=0
pass() { echo "PASS: $1"; }
fk()   { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  detail: $2" >&2; fail=1; }

# Build an offline repo with a real origin + default branch.
FIX=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$FIX"' EXIT
git init -q --bare "$FIX/remote.git"
git clone -q "$FIX/remote.git" "$FIX/work" 2>/dev/null
cd "$FIX/work" || exit 1
git "${GIT_ID[@]}" symbolic-ref HEAD refs/heads/main
echo seed > f; git add f; git "${GIT_ID[@]}" commit -qm seed
git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null

# --- CC-bad: bad args -> exit 1 ---
out=$(bash "$SUT" 2>/dev/null); rc=$?
[ "$rc" -eq 1 ] && pass "CC-bad: no args -> exit 1" || fk "CC-bad exit" "rc=$rc"

# --- CC-zero: --issue 0 is not a positive integer -> exit 1 ---
bash "$SUT" --issue 0 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "CC-zero: --issue 0 rejected" || fk "CC-zero" "rc=$rc"

# --- CC-clear: --issue with no signals -> VERDICT=clear, exit 0 ---
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"
printf '{"number":624,"title":"x","state":"OPEN","comments":[]}' > "$FIX/empty.json"
out=$(bash "$SUT" --issue 624 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "VERDICT=clear" ]; } \
  && pass "CC-clear: no signals -> clear" || fk "CC-clear" "rc=$rc out=$out"

# --- CC-grammar: stdout is exactly one VERDICT= line ---
lines=$(printf '%s\n' "$out" | grep -c '^VERDICT=')
{ [ "$lines" -eq 1 ] && printf '%s' "$out" | grep -qE '^VERDICT=(clear|warn-reattach|block)$'; } \
  && pass "CC-grammar: single well-formed token" || fk "CC-grammar" "out=$out"

# --- CC-claim: recorded claim present -> warn-reattach ---
# Escaped \\n so the body is valid JSON (a literal newline inside a JSON string
# is invalid; real `gh --json` output escapes newlines the same way).
printf '{"number":624,"title":"x","state":"OPEN","comments":[{"body":"<!-- pipeline-state:log -->\\n- 2026-06-09T00:00:00Z — /start exited, branch: feat/624-collision-mvp\\n"}]}' > "$FIX/claim.json"
export ARBO_COLLISION_ISSUE_JSON="$FIX/claim.json"
out=$(bash "$SUT" --issue 624 2>/dev/null)
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-claim: recorded claim -> warn" || fk "CC-claim" "out=$out"

# --- CC-ondisk: local branch for the issue exists -> warn-reattach ---
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"   # no recorded claim
git branch feat/624-collision-mvp >/dev/null 2>&1
out=$(bash "$SUT" --issue 624 2>/dev/null)
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-ondisk: local branch -> warn" || fk "CC-ondisk" "out=$out"

# --- CC-block: branch for the issue is checked out in another worktree -> block ---
git worktree add -q "$FIX/wt624" feat/624-collision-mvp 2>/dev/null
out=$(bash "$SUT" --issue 624 2>/dev/null)
[ "$out" = "VERDICT=block" ] && pass "CC-block: live worktree -> block" || fk "CC-block" "out=$out"
git worktree remove --force "$FIX/wt624" 2>/dev/null; git branch -D feat/624-collision-mvp >/dev/null 2>&1

# --- CC-self: --issue from WITHIN the issue's own worktree -> clear (not block) ---
# Regression for the B4 correctness finding: the caller's own branch must be
# excluded from the collision signals ("block" = checked out in ANOTHER worktree).
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"
git worktree add -q "$FIX/wtself" -b feat/909-self 2>/dev/null
out=$( cd "$FIX/wtself" && bash "$SUT" --issue 909 2>/dev/null )
[ "$out" = "VERDICT=clear" ] && pass "CC-self: own worktree -> clear" || fk "CC-self" "out=$out"
# With a SECOND branch for the same issue, the other one is the collision.
git branch feat/909-other >/dev/null 2>&1
out=$( cd "$FIX/wtself" && bash "$SUT" --issue 909 2>/dev/null )
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-self2: sibling branch -> warn" || fk "CC-self2" "out=$out"
git branch -D feat/909-other >/dev/null 2>&1; git worktree remove --force "$FIX/wtself" 2>/dev/null

# --- CC-pc-clear: single branch for the issue -> clear ---
git worktree add -q "$FIX/wtA" -b feat/700-alpha 2>/dev/null
out=$( cd "$FIX/wtA" && bash "$SUT" --pre-commit 2>/dev/null )
[ "$out" = "VERDICT=clear" ] && pass "CC-pc-clear: one branch -> clear" || fk "CC-pc-clear" "out=$out"

# --- CC-pc-warn: a second branch for the same issue exists -> warn-reattach ---
git branch feat/700-beta >/dev/null 2>&1
out=$( cd "$FIX/wtA" && bash "$SUT" --pre-commit 2>/dev/null )
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-pc-warn: two branches same issue -> warn" || fk "CC-pc-warn" "out=$out"
git branch -D feat/700-beta >/dev/null 2>&1; git worktree remove --force "$FIX/wtA" 2>/dev/null

# --- CC-pc-offline: --pre-commit ignores any claim fixture (local-only) ---
export ARBO_COLLISION_ISSUE_JSON="$FIX/claim.json"
git worktree add -q "$FIX/wtO" -b feat/800-only 2>/dev/null
out=$( cd "$FIX/wtO" && bash "$SUT" --pre-commit 2>/dev/null )
[ "$out" = "VERDICT=clear" ] && pass "CC-pc-offline: claim fixture ignored" || fk "CC-pc-offline" "out=$out"
git worktree remove --force "$FIX/wtO" 2>/dev/null; unset ARBO_COLLISION_ISSUE_JSON

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
