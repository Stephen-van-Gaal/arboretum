#!/usr/bin/env bash
# owner: roadmap
# Smoke test for scripts/roadmap/audit-board.sh
#
# Builds a fixture board, asserts each issue lands in the expected bucket.
# Exists to catch regressions in the categorization logic — particularly
# around the "blocked" precedence and the "active needs horizon" rule.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/roadmap/audit-board.sh"
FIXTURE="$SCRIPT_DIR/_fixtures/roadmap/board-state.json"

[ -f "$AUDIT" ]   || { echo "FAIL: $AUDIT not found"   >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FAIL: $FIXTURE not found" >&2; exit 1; }

# Note: bash 3.2 (default macOS) doesn't have 'declare -A' inline init,
# so we use parallel arrays instead.
nums=(1 2 3 4 5)
expected=(speculative inbox well_scoped active other)
descriptions=(
  "stale unlabeled (created 9+ months ago)"
  "fresh, no horizon"
  "type+horizon, no recent comments"
  "horizon:now + recent comments"
  "blocked → other (precedence rule)"
)

result="$(bash "$AUDIT" --board-file "$FIXTURE" --as-of 2026-05-09)"

# JSON validity
echo "$result" | jq -e . >/dev/null || {
  echo "FAIL: audit output is not valid JSON" >&2
  echo "$result" >&2
  exit 1
}

fail=0
for i in "${!nums[@]}"; do
  n="${nums[$i]}"
  want="${expected[$i]}"
  desc="${descriptions[$i]}"
  got="$(echo "$result" | jq -r --arg n "$n" '.issues[$n] // "MISSING"')"
  if [ "$got" = "$want" ]; then
    echo "PASS  #$n  ($desc) → $got"
  else
    echo "FAIL  #$n  ($desc) → expected $want, got $got"
    fail=1
  fi
done

# Sanity: counts add up to total
total="$(echo "$result" | jq '[.counts | to_entries[].value] | add')"
[ "$total" = "5" ] || { echo "FAIL: counts sum to $total, expected 5"; fail=1; }

exit $fail
