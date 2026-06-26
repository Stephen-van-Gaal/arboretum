#!/usr/bin/env bash
# owner: session-heartbeat
# scope: plugin-only
# ci-parallel: safe
# Contract-conformance smoke for the heartbeat seam (docs/contracts/heartbeat.contract.md).
# Asserts the sentinel JSON shape, the non-issue no-op, the liveness boundary, and
# the branch->issue mapping. Auto-discovered by ci-checks.sh's _smoke-test-* glob.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_ID=(-c user.email=t@t -c user.name=t)
fail=0
pass() { echo "PASS: $1"; }
fk()   { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  detail: $2" >&2; fail=1; }

FIX=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$FIX"' EXIT
git init -q "$FIX/work"; cd "$FIX/work" || exit 1
git "${GIT_ID[@]}" commit -q --allow-empty -m seed
git "${GIT_ID[@]}" checkout -q -b feat/715-heartbeat
# shellcheck source=/dev/null
source "$ROOT/scripts/heartbeat.sh"
HB_DIR="$FIX/work/.arboretum/heartbeat"
export ARBO_HEARTBEAT_TTL_SECONDS=14400

# HBC-1: sentinel shape
heartbeat_touch
s="$HB_DIR/feat-715-heartbeat.json"
if [ -f "$s" ] && python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d["last_seen"],int)
assert d["branch"] and d["worktree_path"] and d["last_seen_iso"]' "$s" 2>/dev/null; then
  pass "HBC-1: sentinel shape"
else fk "HBC-1" "$(cat "$s" 2>&1)"; fi

# HBC-2: non-issue no-op
git "${GIT_ID[@]}" checkout -q -b scratch-no-issue 2>/dev/null
rm -rf "$HB_DIR"; heartbeat_touch
{ [ ! -d "$HB_DIR" ] || [ -z "$(ls -A "$HB_DIR" 2>/dev/null)" ]; } \
  && pass "HBC-2: non-issue no-op" || fk "HBC-2" "$(ls -la "$HB_DIR" 2>&1)"

# HBC-3: liveness boundary
mkdir -p "$HB_DIR"; now=$(date +%s)
wr() { ARBO_S_T="$2" python3 -c 'import json,os,sys
json.dump({"branch":"feat/715-heartbeat","worktree_path":"/x","last_seen":int(os.environ["ARBO_S_T"]),"last_seen_iso":"x"},open(sys.argv[1],"w"))' "$HB_DIR/$1.json"; }
wr feat-715-heartbeat "$now"
heartbeat_branch_is_live feat/715-heartbeat \
  && pass "HBC-3a: fresh -> live" || fk "HBC-3a"
wr feat-715-heartbeat "$((now-14400-100))"
heartbeat_branch_is_live feat/715-heartbeat \
  && fk "HBC-3b: expired read live" || pass "HBC-3b: expired -> not live"

# HBC-4: liveness is branch-specific (a feat/715 sentinel != another branch)
wr feat-715-heartbeat "$now"
heartbeat_branch_is_live feat/999-other \
  && fk "HBC-4: unrelated branch read live" || pass "HBC-4: branch-specific"

exit "$fail"
