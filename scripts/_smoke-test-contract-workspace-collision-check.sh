#!/usr/bin/env bash
# owner: collision-detection
# Contract test for docs/contracts/workspace-collision-check.contract.md
# (seam: workspace-collision-check). Asserts the D4 output contract +
# signal->verdict mapping. Picked up automatically by ci-checks.sh.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/workspace-collision-check.sh"
[ -f "$SUT" ] || { echo "FAIL: $SUT not found" >&2; exit 1; }
GIT_ID=(-c user.email=t@t -c user.name=t)
fail=0; pass() { echo "PASS: $1"; }; fk() { echo "FAIL: $1" >&2; fail=1; }

FIX=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$FIX"' EXIT
git init -q --bare "$FIX/remote.git"; git clone -q "$FIX/remote.git" "$FIX/work" 2>/dev/null
cd "$FIX/work" || exit 1
git "${GIT_ID[@]}" symbolic-ref HEAD refs/heads/main
echo s > f; git add f; git "${GIT_ID[@]}" commit -qm s
git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null

# CWCC-1: exit-code contract — bad args -> exit 1 (operational error)
bash "$SUT" >/dev/null 2>&1; [ "$?" -eq 1 ] && pass "CWCC-1 bad args exit 1" || fk "CWCC-1"

# CWCC-2: token grammar — output is exactly one VERDICT=<enum> line, exit 0
printf '{"number":1,"state":"OPEN","comments":[]}' > "$FIX/e.json"
out=$(ARBO_COLLISION_ISSUE_JSON="$FIX/e.json" bash "$SUT" --issue 1 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
    && printf '%s' "$out" | grep -qE '^VERDICT=(clear|warn-reattach|block)$'; } \
  && pass "CWCC-2 single well-formed token, exit 0" || fk "CWCC-2"

# CWCC-3: mapping — recorded claim -> warn-reattach
printf '{"number":1,"state":"OPEN","comments":[{"body":"<!-- pipeline-state:log -->\\n- t — /start exited, branch: feat/1-x\\n"}]}' > "$FIX/c.json"
out=$(ARBO_COLLISION_ISSUE_JSON="$FIX/c.json" bash "$SUT" --issue 1 2>/dev/null)
[ "$out" = "VERDICT=warn-reattach" ] && pass "CWCC-3 claim -> warn-reattach" || fk "CWCC-3"

# CWCC-4: mapping — live worktree for the issue -> block
git worktree add -q "$FIX/w1" -b feat/1-x 2>/dev/null
out=$(ARBO_COLLISION_ISSUE_JSON="$FIX/e.json" bash "$SUT" --issue 1 2>/dev/null)
[ "$out" = "VERDICT=block" ] && pass "CWCC-4 live worktree -> block" || fk "CWCC-4"
git worktree remove --force "$FIX/w1" 2>/dev/null

# CWCC-5: --pre-commit performs no network and stays local-only (>=2 -> warn)
git worktree add -q "$FIX/wa" -b feat/9-a 2>/dev/null; git branch feat/9-b >/dev/null 2>&1
out=$( cd "$FIX/wa" && bash "$SUT" --pre-commit 2>/dev/null )
[ "$out" = "VERDICT=warn-reattach" ] && pass "CWCC-5 pre-commit >=2 -> warn" || fk "CWCC-5"

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
