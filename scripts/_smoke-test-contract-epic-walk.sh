#!/usr/bin/env bash
# owner: epic-aware-orientation
# _smoke-test-contract-epic-walk.sh — Contract test for
# docs/contracts/epic-walk.contract.md (EW-1..EW-7). Fixture-driven; no network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALK="$SCRIPT_DIR/roadmap/epic-walk.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/epic-walk"
[ -f "$WALK" ] || { echo "FAIL: $WALK not found" >&2; exit 1; }
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

# EW-1: epic with active children lists ALL of them, no "next"
out=$(bash "$WALK" --graph-file "$FIX/in-flight.json")
printf '%s' "$out" | python3 -c 'import json,sys;e=json.load(sys.stdin)["epics_in_flight"][0];assert [c["number"] for c in e["active"]]==[305,306];assert e["next"] is None;assert e["done"]==1 and e["total"]==3' \
  && pass "EW-1 active children listed, next null, progress 1/3" \
  || failc "EW-1 active listing" "$out"

# EW-2: no active → single ready next, earlier blocked printed below
out=$(bash "$WALK" --graph-file "$FIX/ready-blocked.json")
printf '%s' "$out" | python3 -c 'import json,sys;e=[x for x in json.load(sys.stdin)["epics_in_flight"] if x["number"]==404][0];assert e["active"]==[];assert e["next"]["number"]==273;assert [b["number"] for b in e["blocked"]]==[272]' \
  && pass "EW-2 ready-then-native next, blocked-below" || failc "EW-2 next selection" "$out"

# EW-3: all-blocked → no false next, blocker shown
out=$(bash "$WALK" --graph-file "$FIX/all-blocked.json")
printf '%s' "$out" | python3 -c 'import json,sys;e=[x for x in json.load(sys.stdin)["epics_in_flight"] if x["number"]==446][0];assert e["next"] is None;assert [b["number"] for b in e["blocked"]]==[451]' \
  && pass "EW-3 all-blocked no false next" || failc "EW-3 all-blocked" "$out"

# EW-4: inclusion — parent-of-next-up appears even with no active child (all-blocked #446 is parent of next-up 451)
printf '%s' "$out" | python3 -c 'import json,sys;ns=[x["number"] for x in json.load(sys.stdin)["epics_in_flight"]];assert 446 in ns' \
  && pass "EW-4 inclusion parent-of-next-up" || failc "EW-4 inclusion" "$out"

# EW-5: #404 is parent-of-next-up (#273) in ready-blocked.json, so it must appear in epics_in_flight
out=$(bash "$WALK" --graph-file "$FIX/ready-blocked.json")
printf '%s' "$out" | python3 -c 'import json,sys;ns=[x["number"] for x in json.load(sys.stdin)["epics_in_flight"]];assert 404 in ns' \
  && pass "EW-5 parent-of-next-up epic included" || failc "EW-5 inclusion-by-parent-of-next-up (404 is parent of next-up 273)" "$out"

# EW-6: recursion — closed leaf's immediate epic (#110) is complete; walk up to #100, next ready = #101
out=$(bash "$WALK" --graph-file "$FIX/recursion.json")
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);a=d["auto_advance"];assert a is not None and a["from"]==111 and a["to"]==101 and a["epic"]==100, a' \
  && pass "EW-6 recursion walk-up auto-advance" || failc "EW-6 recursion" "$out"

# EW-7: open next-up with no epic parent → empty in-flight list (unlinked) and no auto-advance (open, not closed)
out=$(bash "$WALK" --graph-file "$FIX/unlinked.json")
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["epics_in_flight"]==[] and d["auto_advance"] is None' \
  && pass "EW-7 unlinked degrades to empty" || failc "EW-7 unlinked" "$out"

exit $fail
