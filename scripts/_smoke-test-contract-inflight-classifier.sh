#!/usr/bin/env bash
# owner: inflight-work-classifier
# scope: plugin-only
# _smoke-test-contract-inflight-classifier.sh — Contract test for
# docs/contracts/inflight-classifier.contract.md (IC-1..IC-9). Fixture-driven;
# no network. Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFLIGHT="$SCRIPT_DIR/roadmap/inflight.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/inflight"
[ -f "$INFLIGHT" ] || { echo "FAIL: $INFLIGHT not found" >&2; exit 1; }
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

# IC-6: local-signal branch/worktree → issue number parsing.
out=$(printf 'feat/703-foo\nfix/624-bar\nmain\nfeat/no-number\n' | bash "$INFLIGHT" --signals-stdin)
printf '%s' "$out" | python3 -c 'import sys;s=set(int(x) for x in sys.stdin.read().split());assert s=={703,624}, s' \
  && pass "IC-6 local-signal branch->number" || failc "IC-6" "$out"

# IC-1..IC-4: classify the basic board (epic #516 + naked 624/305/671 via signals file)
out=$(bash "$INFLIGHT" --graph-file "$FIX/board-basic.json" --signals-file "$FIX/signals-basic.txt")
# IC-1 taxonomy: 516 is an epic; 624/305/671 are naked; 677/665/304 are NOT naked
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);en=[e["number"] for e in d["epics"]];nn=[n["number"] for n in d["naked_issues"]];assert en==[516];assert sorted(nn)==[305,624,671];assert not (set(nn)&{677,665,304})' \
  && pass "IC-1 taxonomy" || failc "IC-1" "$out"
# IC-2 signal precedence (stage > pr > branch)
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);sig={n["number"]:n["signal"] for n in d["naked_issues"]};assert sig[624]=="stage:design";assert sig[305]=="pr";assert sig[671]=="branch"' \
  && pass "IC-2 signal precedence" || failc "IC-2" "$out"
# IC-3 epic inclusion + done/total + active
printf '%s' "$out" | python3 -c 'import json,sys;e=json.load(sys.stdin)["epics"][0];assert e["done"]==1 and e["total"]==3;assert [a["number"] for a in e["active"]]==[677]' \
  && pass "IC-3 epic inclusion" || failc "IC-3" "$out"
# IC-4 sub-issues nested, classes assigned
printf '%s' "$out" | python3 -c 'import json,sys;e=json.load(sys.stdin)["epics"][0];si={s["number"]:s["class"] for s in e["sub_issues"]};assert si[677]=="active" and si[665]=="ready"' \
  && pass "IC-4 sub_issues" || failc "IC-4" "$out"

# IC-5 degraded propagates
outd=$(bash "$INFLIGHT" --graph-file "$FIX/board-degraded.json" --signals-file "$FIX/signals-basic.txt")
printf '%s' "$outd" | python3 -c 'import json,sys;assert json.load(sys.stdin)["degraded"] is True' \
  && pass "IC-5 degraded" || failc "IC-5" "$outd"

# IC-7 --unassigned keeps only empty-assignee nodes (naked + sub_issues);
# epic header counts done/total stay unfiltered.
out=$(bash "$INFLIGHT" --graph-file "$FIX/board-basic.json" --signals-file "$FIX/signals-basic.txt" --unassigned)
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);nn=sorted(n["number"] for n in d["naked_issues"]);assert nn==[305,671], nn;assert d["filter"]=="unassigned";si=[s["number"] for e in d["epics"] for s in e["sub_issues"]];assert 677 not in si' \
  && pass "IC-7 --unassigned" || failc "IC-7" "$out"

# IC-8 --me (viewer seam = stvangaal) keeps only viewer-assigned; epic kept via
# #677; done/total unfiltered.
out=$(bash "$INFLIGHT" --graph-file "$FIX/board-basic.json" --signals-file "$FIX/signals-basic.txt" --me --viewer stvangaal)
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["viewer"]=="stvangaal" and d["filter"]=="me";nn=sorted(n["number"] for n in d["naked_issues"]);assert nn==[624], nn;e=d["epics"][0];assert [s["number"] for s in e["sub_issues"]]==[677];assert e["done"]==1 and e["total"]==3' \
  && pass "IC-8 --me" || failc "IC-8" "$out"

# IC-9 --me with unresolvable identity → non-zero, no board.
if bash "$INFLIGHT" --graph-file "$FIX/board-basic.json" --me --viewer "" >/dev/null 2>&1; then
  failc "IC-9 should have failed on unresolvable identity"
else
  pass "IC-9 --me unresolvable fails loudly"
fi

# IC-12: consumer-side scrub of person fields. Author-controlled handles carrying
# ANSI escapes must be scrubbed at the classifier boundary (defense-in-depth —
# scrub at producer AND consumer) — no ESC byte (\x1b) survives into any emitted
# author or assignees, across epic/sub_issue/naked surfaces.
out=$(bash "$INFLIGHT" --graph-file "$FIX/board-hostile-handles.json")
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ESC = "\x1b"
vals = []
for e in d["epics"]:
    vals.append(e.get("author"))
    for s in e["sub_issues"]:
        vals.append(s.get("author"))
        vals.extend(s.get("assignees", []))
for n in d["naked_issues"]:
    vals.append(n.get("author"))
    vals.extend(n.get("assignees", []))
assert vals, "expected person fields in output"
for v in vals:
    assert v is None or ESC not in v, repr(v)
' && pass "IC-12 person fields scrubbed at consumer" || failc "IC-12" "$out"

# IC-13: --me fails closed in --graph-file mode without --viewer. With no
# resolvable viewer, --me must exit non-zero (3) and emit NO board (anti-silent;
# never a silent empty board with exit 0).
if out=$(bash "$INFLIGHT" --graph-file "$FIX/board-basic.json" --me 2>/dev/null); then
  failc "IC-13 should have failed: --me with no --viewer in graph-file mode" "$out"
elif printf '%s' "$out" | grep -q '"epics"'; then
  failc "IC-13 emitted a board despite failing" "$out"
else
  pass "IC-13 --me without --viewer fails closed (no board)"
fi

# Live-mode tests use the INFLIGHT_LIB seam to inject a fake lib (no network).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# IC-10 (live): a working board-graph builder → valid seam JSON, exit 0.
cat > "$TMP/lib-ok.sh" <<'LIB'
roadmap_inflight_board_graph() {
  cat "$INFLIGHT_BOARD_FIXTURE"
}
inflight_local_signals() { printf '671\n'; }
LIB
out=$(INFLIGHT_LIB="$TMP/lib-ok.sh" INFLIGHT_BOARD_FIXTURE="$FIX/board-basic.json" bash "$INFLIGHT"); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert [e["number"] for e in d["epics"]]==[516];assert d["degraded"] is False'; then
  pass "IC-10 live mode valid seam"
else
  failc "IC-10 (rc=$rc)" "$out"
fi

# IC-11 (live): a failing board-graph builder → degraded:true, exit 0, never crash.
cat > "$TMP/lib-fail.sh" <<'LIB'
roadmap_inflight_board_graph() { return 1; }
inflight_local_signals() { return 0; }
LIB
out=$(INFLIGHT_LIB="$TMP/lib-fail.sh" bash "$INFLIGHT"); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["degraded"] is True;assert d["epics"]==[] and d["naked_issues"]==[]'; then
  pass "IC-11 live mode fail-soft degraded"
else
  failc "IC-11 (rc=$rc)" "$out"
fi

exit $fail
