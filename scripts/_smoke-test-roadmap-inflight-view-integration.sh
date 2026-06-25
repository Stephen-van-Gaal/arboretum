#!/usr/bin/env bash
# owner: roadmap-inflight-view
# scope: plugin-only
# _smoke-test-roadmap-inflight-view-integration.sh — full `--format full` render
# over a fixture board, asserting in-flight-first order, de-dup against buckets,
# no truncation of a #516-class epic, and the degradation notice. No network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$SCRIPT_DIR/roadmap/view.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/roadmap-inflight-view"
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

out="$(bash "$VIEW" --format full --board-file "$FIX/board.json" \
        --closed-file "$FIX/closed.json" --inflight-file "$FIX/classified-full.json")"

# INT-RV-1: full ordering IN FLIGHT → NOW → NEXT → ... → DONE → RECOMMEND.
order_ok=true
prev=0
for sec in "IN FLIGHT — ISSUES" "IN FLIGHT — EPICS" "^NOW" "^NEXT" "^LATER" "^SLACK" "^DONE" "RECOMMEND"; do
  ln=$(echo "$out" | grep -nE "$sec" | head -1 | cut -d: -f1)
  [ -z "$ln" ] && continue
  [ "$ln" -le "$prev" ] && order_ok=false
  prev="$ln"
done
$order_ok && pass "INT-RV-1 section order (in-flight-first, DONE tail)" || failc "INT-RV-1" "$out"

# INT-RV-2: #516-class epic is NOT truncated — present in IN FLIGHT — EPICS.
echo "$out" | grep -qE "▸ #516 .*1/3" && pass "INT-RV-2 #516 not truncated" || failc "INT-RV-2" "$out"

# INT-RV-3: de-dup — every in-flight number appears exactly once across the board.
dedup_ok=true
for n in 516 624 305 671 677; do
  c=$(echo "$out" | grep -oE "#$n\b" | wc -l | tr -d ' ')
  [ "$c" -eq 1 ] || { failc "INT-RV-3 #$n appears $c times" "$out"; dedup_ok=false; }
done
$dedup_ok && pass "INT-RV-3 each in-flight unit appears exactly once"

# INT-RV-4: degraded board still renders + notice.
outd="$(bash "$VIEW" --format full --board-file "$FIX/board.json" \
        --closed-file "$FIX/closed.json" --inflight-file "$FIX/classified-degraded.json")"
echo "$outd" | grep -qiE "partial board" && pass "INT-RV-4 degraded notice" || failc "INT-RV-4" "$outd"

exit $fail
