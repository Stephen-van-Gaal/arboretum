#!/usr/bin/env bash
# owner: collision-detection
# scope: plugin-only
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

# Heartbeat seam (#715): sentinels live in the SHARED main-tree dir ($FIX/work),
# which every linked worktree resolves to. A fresh sentinel for an issue's branch
# makes the claim/exists_local path read as live (warn-reattach); a stale/absent
# one reads as abandoned (warn-reclaim).
HB_DIR="$FIX/work/.arboretum/heartbeat"
export ARBO_HEARTBEAT_TTL_SECONDS=14400
hb_write() { # <slug> <branch> <epoch>
  mkdir -p "$HB_DIR"
  ARBO_S_B="$2" ARBO_S_T="$3" python3 -c '
import json,os,sys
json.dump({"branch":os.environ["ARBO_S_B"],"worktree_path":"/x",
           "last_seen":int(os.environ["ARBO_S_T"]),"last_seen_iso":"x"},
          open(sys.argv[1],"w"))' "$HB_DIR/$1.json"
}

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
{ [ "$lines" -eq 1 ] && printf '%s' "$out" | grep -qE '^VERDICT=(clear|warn-reattach|warn-reclaim|warn-crosstool|block)$'; } \
  && pass "CC-grammar: single well-formed token" || fk "CC-grammar" "out=$out"

# --- CC-claim: recorded claim + LIVE sentinel -> warn-reattach ---
# Escaped \\n so the body is valid JSON (a literal newline inside a JSON string
# is invalid; real `gh --json` output escapes newlines the same way).
printf '{"number":624,"title":"x","state":"OPEN","comments":[{"body":"<!-- pipeline-state:log -->\\n- 2026-06-09T00:00:00Z — /start exited, branch: feat/624-collision-mvp\\n"}]}' > "$FIX/claim.json"
export ARBO_COLLISION_ISSUE_JSON="$FIX/claim.json"
hb_write feat-624-collision-mvp feat/624-collision-mvp "$(date +%s)"   # live
out=$(bash "$SUT" --issue 624 2>/dev/null)
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-claim: recorded claim + live -> warn-reattach" || fk "CC-claim" "out=$out"

# --- CC-ondisk: local branch for the issue exists + LIVE sentinel -> warn-reattach ---
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"   # no recorded claim
git branch feat/624-collision-mvp >/dev/null 2>&1
hb_write feat-624-collision-mvp feat/624-collision-mvp "$(date +%s)"   # keep live
out=$(bash "$SUT" --issue 624 2>/dev/null)
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-ondisk: local branch + live -> warn-reattach" || fk "CC-ondisk" "out=$out"

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
hb_write feat-909-other feat/909-other "$(date +%s)"   # live sibling
out=$( cd "$FIX/wtself" && bash "$SUT" --issue 909 2>/dev/null )
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-self2: sibling branch + live -> warn-reattach" || fk "CC-self2" "out=$out"
# CC-self3 (regression, B4 finding): the caller's OWN fresh sentinel must not mask
# a DEAD sibling. Caller on feat/909-self with its own fresh sentinel; sibling
# feat/909-other has NO sentinel -> must be warn-reclaim, not warn-reattach.
rm -rf "$HB_DIR"
hb_write feat-909-self feat/909-self "$(date +%s)"      # own branch live
out=$( cd "$FIX/wtself" && bash "$SUT" --issue 909 2>/dev/null )
[ "$out" = "VERDICT=warn-reclaim" ] && pass "CC-self3: own live session does not mask dead sibling" || fk "CC-self3" "out=$out"
rm -rf "$HB_DIR"
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

# ===== Liveness split (#715): warn-reattach (live) vs warn-reclaim (dead) =====
# Same recorded claim for issue 624; only the sentinel freshness changes.
rm -rf "$HB_DIR"
export ARBO_COLLISION_ISSUE_JSON="$FIX/claim.json"
now=$(date +%s)

# Claim + STALE sentinel -> warn-reclaim (dead session).
hb_write feat-624-collision-mvp feat/624-collision-mvp "$((now - 14400 - 100))"
out=$(bash "$SUT" --issue 624 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "VERDICT=warn-reclaim" ]; } \
  && pass "CC-reclaim: claim + stale sentinel -> warn-reclaim" || fk "CC-reclaim" "rc=$rc out=$out"

# Claim + NO sentinel at all -> warn-reclaim (absent == dead).
rm -rf "$HB_DIR"
out=$(bash "$SUT" --issue 624 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "VERDICT=warn-reclaim" ]; } \
  && pass "CC-reclaim-nosentinel: claim + no sentinel -> warn-reclaim" || fk "CC-reclaim-nosentinel" "rc=$rc out=$out"

# Claim + FRESH sentinel -> warn-reattach (live session).
hb_write feat-624-collision-mvp feat/624-collision-mvp "$now"
out=$(bash "$SUT" --issue 624 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "VERDICT=warn-reattach" ]; } \
  && pass "CC-reattach-live: claim + fresh sentinel -> warn-reattach" || fk "CC-reattach-live" "rc=$rc out=$out"
rm -rf "$HB_DIR"; unset ARBO_COLLISION_ISSUE_JSON

# CC-multi (regression, Codex P2): with multiple local branches for one issue and
# no claim, a LIVE sibling must win even if another sibling is stale (no arbitrary
# stale pick reclaiming). feat/888-a live + feat/888-b stale -> warn-reattach.
printf '{"number":888,"title":"x","state":"OPEN","comments":[]}' > "$FIX/e888.json"
export ARBO_COLLISION_ISSUE_JSON="$FIX/e888.json"
git branch feat/888-a >/dev/null 2>&1; git branch feat/888-b >/dev/null 2>&1
rm -rf "$HB_DIR"
hb_write feat-888-b feat/888-b "$(( $(date +%s) - 14400 - 100 ))"   # stale sibling
hb_write feat-888-a feat/888-a "$(date +%s)"                        # live sibling
err888="$FIX/err888"
out=$(bash "$SUT" --issue 888 2>"$err888")
[ "$out" = "VERDICT=warn-reattach" ] && pass "CC-multi: a live sibling wins over a stale one" || fk "CC-multi" "out=$out"
# The reattach reason must name the LIVE branch (feat/888-a), not the arbitrary
# inflight pick (feat/888-b).
grep -q "feat/888-a" "$err888" && pass "CC-multi2: reattach reason names the live branch" || fk "CC-multi2" "$(cat "$err888")"
git branch -D feat/888-a feat/888-b >/dev/null 2>&1; rm -rf "$HB_DIR"; unset ARBO_COLLISION_ISSUE_JSON

# ===== Cross-tool (#714): detached Codex worktrees =====
# Codex worktrees are DETACHED linked worktrees under $CODEX_HOME/worktrees,
# reproduced here with `git worktree add --detach` (no Codex needed).
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"          # no recorded claim
CODEX_HM="$FIX/codex-home"; mkdir -p "$CODEX_HM/worktrees"   # under $FIX so the EXIT trap cleans it
git "${GIT_ID[@]}" branch feat/714-cross-tool-signals >/dev/null 2>&1

# --- CT-1: correlated Codex worktree, caller on main -> warn-crosstool (D8: > warn-reattach) ---
git "${GIT_ID[@]}" worktree add -q --detach "$CODEX_HM/worktrees/wt1" feat/714-cross-tool-signals 2>/dev/null
out=$(CODEX_HOME="$CODEX_HM" bash "$SUT" --issue 714 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "VERDICT=warn-crosstool" ]; } \
  && pass "CT-1: correlated codex worktree -> warn-crosstool (> warn-reattach)" || fk "CT-1" "rc=$rc out=$out"

# --- CT-2: block outranks crosstool (own-tool branch checked out elsewhere + codex) ---
git "${GIT_ID[@]}" worktree add -q "$FIX/own2" feat/714-cross-tool-signals 2>/dev/null
out=$(CODEX_HOME="$CODEX_HM" bash "$SUT" --issue 714 2>/dev/null)
[ "$out" = "VERDICT=block" ] && pass "CT-2: block outranks crosstool" || fk "CT-2" "out=$out"
git worktree remove --force "$FIX/own2" 2>/dev/null
git worktree remove --force "$CODEX_HM/worktrees/wt1" 2>/dev/null

# Caller sits ON feat/714 (own-branch suppresses warn-reattach) to isolate crosstool.
git "${GIT_ID[@]}" worktree add -q "$FIX/caller714" feat/714-cross-tool-signals 2>/dev/null

# --- CT-3: a NON-codex detached worktree at the tip -> ignored -> clear ---
git "${GIT_ID[@]}" worktree add -q --detach "$FIX/usrwt" feat/714-cross-tool-signals 2>/dev/null
out=$( cd "$FIX/caller714" && CODEX_HOME="$CODEX_HM" bash "$SUT" --issue 714 2>/dev/null )
[ "$out" = "VERDICT=clear" ] && pass "CT-3: non-codex detached worktree ignored" || fk "CT-3" "out=$out"
git worktree remove --force "$FIX/usrwt" 2>/dev/null

# --- CT-4: a Codex detached worktree at the tip (caller on its branch) -> warn-crosstool ---
git "${GIT_ID[@]}" worktree add -q --detach "$CODEX_HM/worktrees/wt4" feat/714-cross-tool-signals 2>/dev/null
out=$( cd "$FIX/caller714" && CODEX_HOME="$CODEX_HM" bash "$SUT" --issue 714 2>/dev/null )
[ "$out" = "VERDICT=warn-crosstool" ] && pass "CT-4: codex worktree on own branch -> warn-crosstool" || fk "CT-4" "out=$out"

# --- CT-5: uncorrelated Codex worktree (committed past tip), no local branch -> clear (silent, D7) ---
( cd "$CODEX_HM/worktrees/wt4" && echo x > g && git "${GIT_ID[@]}" add g && git "${GIT_ID[@]}" commit -qm past )
git worktree remove --force "$FIX/caller714" 2>/dev/null
git branch -D feat/714-cross-tool-signals >/dev/null 2>&1
out=$(CODEX_HOME="$CODEX_HM" bash "$SUT" --issue 714 2>/dev/null)
[ "$out" = "VERDICT=clear" ] && pass "CT-5: uncorrelated codex worktree -> clear (silent)" || fk "CT-5" "out=$out"
git worktree remove --force "$CODEX_HM/worktrees/wt4" 2>/dev/null

# --- CT-6: CODEX_HOME with a trailing slash still classifies (Copilot review fix) ---
export ARBO_COLLISION_ISSUE_JSON="$FIX/empty.json"
git "${GIT_ID[@]}" branch feat/714-cross-tool-signals >/dev/null 2>&1
git "${GIT_ID[@]}" worktree add -q --detach "$CODEX_HM/worktrees/wt6" feat/714-cross-tool-signals 2>/dev/null
out=$(CODEX_HOME="$CODEX_HM/" bash "$SUT" --issue 714 2>/dev/null)   # note trailing slash
[ "$out" = "VERDICT=warn-crosstool" ] && pass "CT-6: trailing-slash CODEX_HOME normalized" || fk "CT-6" "out=$out"
git worktree remove --force "$CODEX_HM/worktrees/wt6" 2>/dev/null
git branch -D feat/714-cross-tool-signals >/dev/null 2>&1
unset ARBO_COLLISION_ISSUE_JSON

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
