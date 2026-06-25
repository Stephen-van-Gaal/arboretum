#!/usr/bin/env bash
# owner: inflight-work-classifier
# scope: plugin-only
# _smoke-test-inflight-classifier-integration.sh — Integration coverage for the
# classified board over a faithful multi-epic fixture (issues + native links +
# PR map + worktree set). Asserts the full seam end to end, the board-wide
# epic-discovery (#573 fix — no next_up needed), idle-epic exclusion, and the
# degraded path. Fixture-driven; no network. Picked up by ci-checks.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFLIGHT="$SCRIPT_DIR/roadmap/inflight.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/inflight"
[ -f "$INFLIGHT" ] || { echo "FAIL: $INFLIGHT not found" >&2; exit 1; }
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

out=$(bash "$INFLIGHT" --graph-file "$FIX/board-faithful.json" --signals-file "$FIX/signals-faithful.txt")

# INT-1: two in-flight epics surfaced board-wide (#573 fix — no next_up), idle
# epic #900 (no done/active child) EXCLUDED.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
en = sorted(e["number"] for e in d["epics"])
assert en == [516, 701], en
assert 900 not in en
' && pass "INT-1 board-wide epic discovery, idle excluded" || failc "INT-1" "$out"

# INT-2: naked issues are the in-flight, no-epic-ancestor set with correct
# signals; #888 (open, no signal) excluded; epic children never appear as naked.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
naked = {n["number"]: n["signal"] for n in d["naked_issues"]}
assert sorted(naked) == [305, 624, 671], sorted(naked)
assert naked[624] == "stage:design"
assert naked[305] == "pr"
assert naked[671] == "branch"
assert 888 not in naked
assert not (set(naked) & {677, 665, 304, 703, 704, 706, 901, 902})
' && pass "INT-2 naked signals + no double-listing" || failc "INT-2" "$out"

# INT-3: epic sub_issue classification (active/ready/blocked) + unfiltered
# done/total progress for both surfaced epics.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {e["number"]: e for e in d["epics"]}
e516 = by[516]
assert e516["done"] == 1 and e516["total"] == 3, (e516["done"], e516["total"])
cls516 = {s["number"]: s["class"] for s in e516["sub_issues"]}
assert cls516[677] == "active" and cls516[665] == "ready"
e701 = by[701]
cls701 = {s["number"]: s["class"] for s in e701["sub_issues"]}
assert cls701[703] == "active" and cls701[704] == "ready" and cls701[706] == "blocked", cls701
' && pass "INT-3 sub_issue classes + progress" || failc "INT-3" "$out"

# INT-4: degraded path propagates honestly.
outd=$(bash "$INFLIGHT" --graph-file "$FIX/board-degraded.json" --signals-file "$FIX/signals-basic.txt")
printf '%s' "$outd" | python3 -c 'import json,sys;assert json.load(sys.stdin)["degraded"] is True' \
  && pass "INT-4 degraded propagation" || failc "INT-4" "$outd"

exit $fail
