#!/usr/bin/env bash
# owner: session-heartbeat
# scope: plugin-only
# ci-parallel: serial
# Unit smoke for scripts/heartbeat.sh. Picked up by ci-checks.sh's smoke loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_ID=(-c user.email=t@t -c user.name=t)
fail=0
pass() { echo "PASS: $1"; }
fk()   { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  detail: $2" >&2; fail=1; }

# Offline repo with origin + default branch, on an issue branch.
FIX=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$FIX"' EXIT
git init -q --bare "$FIX/remote.git"
git clone -q "$FIX/remote.git" "$FIX/work" 2>/dev/null
cd "$FIX/work" || exit 1
git "${GIT_ID[@]}" symbolic-ref HEAD refs/heads/main
echo seed > f; git add f; git "${GIT_ID[@]}" commit -qm seed
git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null
git "${GIT_ID[@]}" checkout -q -b feat/715-heartbeat
# shellcheck source=/dev/null
source "$ROOT/scripts/heartbeat.sh"
HB_DIR="$FIX/work/.arboretum/heartbeat"

# --- HB-1: touch on an issue branch writes a sentinel ---
heartbeat_touch
sentinel="$HB_DIR/feat-715-heartbeat.json"
if [ -f "$sentinel" ] \
   && [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["branch"])' "$sentinel")" = "feat/715-heartbeat" ] \
   && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));exit(0 if isinstance(d["last_seen"],int) and d.get("worktree_path") and d.get("last_seen_iso") else 1)' "$sentinel"; then
  pass "HB-1: touch writes sentinel with branch/path/last_seen"
else
  fk "HB-1: sentinel missing or malformed" "$(ls -la "$HB_DIR" 2>&1)"
fi

# --- HB-2: touch on a non-issue branch (main) is a no-op ---
git "${GIT_ID[@]}" checkout -q main
rm -rf "$HB_DIR"
heartbeat_touch
if [ ! -d "$HB_DIR" ] || [ -z "$(ls -A "$HB_DIR" 2>/dev/null)" ]; then
  pass "HB-2: no-op on non-issue branch"
else
  fk "HB-2: sentinel written on main" "$(ls -la "$HB_DIR" 2>&1)"
fi

# --- HB-3..5: liveness boundary + branch->issue mapping ---
git "${GIT_ID[@]}" checkout -q feat/715-heartbeat
rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"
write_sentinel() { # <slug> <branch> <epoch>
  ARBO_S_B="$2" ARBO_S_T="$3" python3 -c '
import json,os,sys
json.dump({"branch":os.environ["ARBO_S_B"],"worktree_path":"/x",
           "last_seen":int(os.environ["ARBO_S_T"]),"last_seen_iso":"x"},
          open(sys.argv[1],"w"))' "$HB_DIR/$1.json"
}
now=$(date +%s)
export ARBO_HEARTBEAT_TTL_SECONDS=14400

# fresh sentinel -> branch is live
write_sentinel feat-715-heartbeat feat/715-heartbeat "$now"
heartbeat_branch_is_live feat/715-heartbeat \
  && pass "HB-3: fresh sentinel -> live" || fk "HB-3"

# expired sentinel (older than TTL) -> not live
write_sentinel feat-715-heartbeat feat/715-heartbeat "$((now - 14400 - 100))"
heartbeat_branch_is_live feat/715-heartbeat \
  && fk "HB-4: expired read as live" || pass "HB-4: expired sentinel -> not live"

# branch-specific: a feat/715 sentinel does not make a different branch live
write_sentinel feat-715-heartbeat feat/715-heartbeat "$now"
heartbeat_branch_is_live feat/999-other \
  && fk "HB-5: unrelated branch read as live" || pass "HB-5: liveness is branch-specific"

# --- HB-6: age helper returns whole hours since last-seen ---
rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"
write_sentinel feat-715-heartbeat feat/715-heartbeat "$(( $(date +%s) - 7200 ))"  # 2h ago
age=$(heartbeat_age_hours_for_branch feat/715-heartbeat)
[ "$age" = "2" ] && pass "HB-6: age ~2h" || fk "HB-6" "age=$age"

# --- HB-7: touch prunes sentinels older than the hard cap ---
rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"
export ARBO_HEARTBEAT_HARD_CAP_SECONDS=604800
write_sentinel feat-900-stale feat/900-stale "$(( $(date +%s) - 604800 - 100 ))"  # >7d
git "${GIT_ID[@]}" checkout -q feat/715-heartbeat 2>/dev/null
heartbeat_touch                                  # touches 715, prunes 900
if [ ! -f "$HB_DIR/feat-900-stale.json" ] && [ -f "$HB_DIR/feat-715-heartbeat.json" ]; then
  pass "HB-7: prune removes >hard-cap sentinel"
else
  fk "HB-7: prune failed" "$(ls -la "$HB_DIR" 2>&1)"
fi

# --- HB-8: prompt-timestamp hook touches the sentinel and still stamps stdout ---
git "${GIT_ID[@]}" checkout -q feat/715-heartbeat 2>/dev/null
rm -rf "$HB_DIR"
out="$(cd "$FIX/work" && CLAUDE_PROJECT_DIR="$FIX/work" bash "$ROOT/.claude/hooks/prompt-timestamp.sh" </dev/null)"
if printf '%s' "$out" | grep -q 'user prompt submitted' && [ -f "$HB_DIR/feat-715-heartbeat.json" ]; then
  pass "HB-8: prompt hook stamps + touches sentinel"
else
  fk "HB-8: hook did not stamp or touch" "out=$out ; $(ls -la "$HB_DIR" 2>&1)"
fi

# --- HB-9: touch from a LINKED worktree writes into the MAIN tree's shared dir,
#          and a checker in a different worktree sees it (cross-worktree liveness) ---
git "${GIT_ID[@]}" checkout -q main
git "${GIT_ID[@]}" worktree add -q "$FIX/wt716" -b feat/716-other 2>/dev/null
rm -rf "$HB_DIR"
( cd "$FIX/wt716" && source "$ROOT/scripts/heartbeat.sh" && heartbeat_touch )
# Sentinel lands in the MAIN tree ($FIX/work), NOT the linked worktree ($FIX/wt716).
if [ -f "$HB_DIR/feat-716-other.json" ] \
   && [ ! -e "$FIX/wt716/.arboretum/heartbeat/feat-716-other.json" ]; then
  pass "HB-9a: linked-worktree touch lands in shared main-tree dir"
else
  fk "HB-9a: sentinel not in shared dir" "$(ls -la "$HB_DIR" "$FIX/wt716/.arboretum/heartbeat" 2>&1)"
fi
# A checker sourcing from the MAIN tree sees the linked worktree's branch as live.
if ( cd "$FIX/work" && source "$ROOT/scripts/heartbeat.sh" && heartbeat_branch_is_live feat/716-other ); then
  pass "HB-9b: cross-worktree checker sees the live sentinel"
else
  fk "HB-9b: cross-worktree sentinel not seen"
fi
git "${GIT_ID[@]}" worktree remove --force "$FIX/wt716" 2>/dev/null

# --- HB-10: slug-collision guard — two branches sharing a slug don't cross-trip.
# feat/715/foo and feat/715-foo both slug to feat-715-foo.json; the stored branch
# field is the authority, so only the matching branch reads as live. ---
rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"
write_sentinel feat-715-foo feat/715/foo "$(date +%s)"   # sentinel belongs to feat/715/foo
heartbeat_branch_is_live feat/715/foo \
  && pass "HB-10a: matching branch reads live" || fk "HB-10a"
heartbeat_branch_is_live feat/715-foo \
  && fk "HB-10b: colliding-slug branch wrongly read live" || pass "HB-10b: colliding-slug branch not live"

exit "$fail"
