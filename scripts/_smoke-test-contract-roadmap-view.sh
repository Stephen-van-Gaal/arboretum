#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# _smoke-test-contract-roadmap-view.sh — Contract + render test for view.sh
# against docs/contracts/roadmap-view.contract.md. No network: uses the
# --board-file / --graph-file seams. Auto-discovered by ci-checks.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$SCRIPT_DIR/roadmap/view.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/roadmap-view"
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; fail=1; }

# RV-1: empty spec is valid (all defaults)
if echo '{}' | bash "$VIEW" --validate-spec >/dev/null 2>&1; then
  pass "RV-1 empty spec valid"; else fail_case "RV-1 empty spec should validate"; fi

# RV-2: unknown key rejected (exit 3)
echo '{"bogus":1}' | bash "$VIEW" --validate-spec >/dev/null 2>&1
[ $? -eq 3 ] && pass "RV-2 unknown key rejected" || fail_case "RV-2 unknown key must exit 3"

# RV-3: bad enum rejected
echo '{"state":"sideways"}' | bash "$VIEW" --validate-spec >/dev/null 2>&1
[ $? -eq 3 ] && pass "RV-3 bad state enum rejected" || fail_case "RV-3 bad enum must exit 3"

# RV-4: limit out of range rejected
echo '{"limit":5000}' | bash "$VIEW" --validate-spec >/dev/null 2>&1
[ $? -eq 3 ] && pass "RV-4 limit bound enforced" || fail_case "RV-4 limit>200 must exit 3"

# RV-5: text_match must be array of strings
echo '{"text_match":"token"}' | bash "$VIEW" --validate-spec >/dev/null 2>&1
[ $? -eq 3 ] && pass "RV-5 text_match type enforced" || fail_case "RV-5 scalar text_match must exit 3"

# RV-6: text_match filters titles (case-insensitive ANY-term)
out=$(echo '{"text_match":["token"]}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -q "#467" && echo "$out" | grep -q "#174" && ! echo "$out" | grep -q "#621" \
  && pass "RV-6 text_match title filter" || fail_case "RV-6 text_match wrong set" "$out"

# RV-7: label_any filters by label
out=$(echo '{"label_any":["horizon:now"]}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -q "#467" && ! echo "$out" | grep -q "#621" \
  && pass "RV-7 label_any filter" || fail_case "RV-7 label filter wrong" "$out"

# RV-8: zero matches → explicit message, exit 0
out=$(echo '{"text_match":["nonexistentxyz"]}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null); rc=$?
echo "$out" | grep -qi "no matches" && [ $rc -eq 0 ] \
  && pass "RV-8 zero-match message" || fail_case "RV-8 expected no-matches msg, rc=$rc" "$out"

# RV-9: flat view shows horizon label column for matched issues
out=$(echo '{"label_any":["horizon:now"]}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -q "\[horizon:now\]" && pass "RV-9 horizon label column" || fail_case "RV-9 missing label column" "$out"

# RV-10: group_by horizon buckets results under horizon headers
out=$(echo '{"group_by":"horizon"}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -qi "horizon:now" && echo "$out" | grep -qi "horizon:later" \
  && pass "RV-10 group_by horizon" || fail_case "RV-10 horizon grouping missing" "$out"

# RV-11: epic field renders the epic tree with connectors + progress header
out=$(echo '{"epic":622}' | bash "$VIEW" --format view --graph-file "$FIX/graph-github.json" 2>/dev/null)
echo "$out" | grep -q "▸ #622" \
  && echo "$out" | grep -q "├─ #623" \
  && echo "$out" | grep -q "└─ #625" \
  && echo "$out" | grep -q "2 open · 1 done · 3 total" \
  && pass "RV-11 epic tree render" || fail_case "RV-11 epic tree wrong" "$out"

# RV-12: done child marked ✓
echo "$out" | grep -q "#625" && echo "$out" | grep -q "✓" \
  && pass "RV-12 done child marked" || fail_case "RV-12 missing ✓" "$out"

# ── Orientation formats (absorbed from render-run.sh; RRR-* migrated here) ──
# RV-13: condensed header counts + NOW section (deterministic via board-file)
out=$(bash "$VIEW" --format condensed --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -q "\[roadmap\] 4 open · 2 now · 1 next · 1 later · 0 untriaged" \
  && echo "$out" | grep -q "NOW:" && echo "$out" | grep -q "#467" && echo "$out" | grep -q "#174" \
  && pass "RV-13 condensed header + NOW" || fail_case "RV-13 condensed wrong" "$out"

# RV-14: full board view shows the ═ separator, NOW/NEXT/LATER, and RECOMMEND
out=$(bash "$VIEW" --format full --board-file "$FIX/board.json" 2>/dev/null)
echo "$out" | grep -q "═══" && echo "$out" | grep -q "RECOMMEND" \
  && echo "$out" | grep -qE "NOW  \(" && echo "$out" | grep -q "NEXT" \
  && pass "RV-14 full board view sections" || fail_case "RV-14 full view wrong" "$out"

# RV-15: empty board → full view still renders header + empty-state lines, exit 0
out=$(bash "$VIEW" --format full --board-file "$FIX/board-empty.json" 2>/dev/null); rc=$?
echo "$out" | grep -q "0 open" && [ $rc -eq 0 ] \
  && pass "RV-15 full view empty board" || fail_case "RV-15 empty board rc=$rc" "$out"

# RV-16: limit is applied AFTER filtering (max results shown), not as a fetch cap
out=$(echo '{"limit":2}' | bash "$VIEW" --format view --board-file "$FIX/board.json" 2>/dev/null)
n=$(printf '%s\n' "$out" | grep -c '^  #')
[ "$n" -eq 2 ] && pass "RV-16 limit caps shown results (post-filter)" || fail_case "RV-16 expected 2 lines, got $n" "$out"

exit $fail
