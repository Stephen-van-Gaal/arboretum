#!/usr/bin/env bash
# owner: roadmap
# Smoke test for scripts/roadmap/maintain-scan.sh and maintain-apply.sh.
#
# Builds a fixture board, asserts each issue lands in the expected bucket,
# then asserts maintain-apply.sh --dry-run names the right actions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/roadmap/maintain-scan.sh"
APPLY="$SCRIPT_DIR/roadmap/maintain-apply.sh"
ISSUES="$SCRIPT_DIR/_fixtures/roadmap/maintain-issues.json"
PRS="$SCRIPT_DIR/_fixtures/roadmap/maintain-prs.json"

[ -f "$SCAN" ]   || { echo "FAIL: $SCAN not found"   >&2; exit 1; }
[ -f "$ISSUES" ] || { echo "FAIL: $ISSUES not found" >&2; exit 1; }
[ -f "$PRS" ]    || { echo "FAIL: $PRS not found"    >&2; exit 1; }

scan="$(bash "$SCAN" --issues-file "$ISSUES" --prs-file "$PRS" --as-of 2026-05-16)"

# JSON validity
echo "$scan" | jq -e . >/dev/null || {
  echo "FAIL: scan output is not valid JSON" >&2
  echo "$scan" >&2
  exit 1
}

fail=0

# Each fixture issue maps to exactly one expected bucket.
nums=(1 2 3 4 5 6 7 8)
expected=(auto_close auto_close soft_resolved orphan untriaged unshaped_next healthy auto_close)
descriptions=(
  "merged PR closing-keyword reference"
  "all acceptance checkboxes ticked"
  "PR mentions issue without closing keyword"
  "old + no horizon label — orphan beats untriaged"
  "no horizon:* label"
  "horizon:next but body unshaped"
  "horizon:next, shaped — control"
  "closing keyword in PR title only"
)

bucket_of() {
  # Find which bucket array contains issue $1; echo it or "MISSING".
  echo "$scan" | jq -r --argjson n "$1" '
    .buckets
    | to_entries
    | map(select(.value | any(.number == $n)))
    | (.[0].key // "MISSING")'
}

for i in "${!nums[@]}"; do
  n="${nums[$i]}"
  want="${expected[$i]}"
  desc="${descriptions[$i]}"
  if [ "$want" = "healthy" ]; then
    # healthy issues are intentionally absent from .buckets
    got="$(bucket_of "$n")"
    if [ "$got" = "MISSING" ]; then
      echo "PASS  #$n  ($desc) → healthy (omitted)"
    else
      echo "FAIL  #$n  ($desc) → expected healthy/omitted, got $got"
      fail=1
    fi
    continue
  fi
  got="$(bucket_of "$n")"
  if [ "$got" = "$want" ]; then
    echo "PASS  #$n  ($desc) → $got"
  else
    echo "FAIL  #$n  ($desc) → expected $want, got $got"
    fail=1
  fi
done

# Counts sum to all 8 fixture issues
total="$(echo "$scan" | jq '[.counts | to_entries[].value] | add')"
[ "$total" = "8" ] || { echo "FAIL: counts sum to $total, expected 8"; fail=1; }

# Evidence strings are non-empty for every bucketed issue
empty_ev="$(echo "$scan" | jq '[.buckets[][] | select(.evidence == "")] | length')"
[ "$empty_ev" = "0" ] || { echo "FAIL: $empty_ev bucketed issues have empty evidence"; fail=1; }

# ── maintain-apply.sh --dry-run ───────────────────────────────────────
[ -f "$APPLY" ] || { echo "FAIL: $APPLY not found"; exit 1; }
apply_out="$(echo "$scan" | bash "$APPLY" --scan-file - --dry-run)"

check_apply() {
  # $1 = grep pattern, $2 = human description
  if printf '%s\n' "$apply_out" | grep -Fq "$1"; then
    echo "PASS  apply dry-run: $2"
  else
    echo "FAIL  apply dry-run: expected line containing '$1' ($2)"
    fail=1
  fi
}

check_apply "[dry-run] close #1"                        "auto-close #1"
check_apply "[dry-run] close #2"                        "auto-close #2"
check_apply "[dry-run] close #8"                        "auto-close #8 (title closing keyword)"
check_apply "[dry-run] label #3 provisionally-resolved" "soft-state #3"
check_apply "[dry-run] label #4 provisionally-stale"    "orphan flag #4"

# Dry-run must never touch untriaged (#5) or unshaped (#6)
if printf '%s\n' "$apply_out" | grep -Eq '#(5|6)([^0-9]|$)'; then
  echo "FAIL  apply dry-run: touched an interactive-only issue (#5/#6)"
  fail=1
else
  echo "PASS  apply dry-run: left interactive buckets untouched"
fi

# --- Decay buckets (agent-ready lifecycle) --------------------------------
decay_fixture="$SCRIPT_DIR/_fixtures/roadmap/agent-ready-decay-issues.json"
empty_prs="$(mktemp)"; echo '[]' > "$empty_prs"
decay_scan="$(bash "$SCAN" --issues-file "$decay_fixture" --prs-file "$empty_prs" --as-of 2026-05-19)"
rm -f "$empty_prs"

assert_bucket() {  # <bucket> <issue-number>
  if printf '%s' "$decay_scan" | jq -e --arg b "$1" --argjson n "$2" \
      '.buckets[$b] | any(.number == $n)' >/dev/null; then
    echo "PASS  decay: #$2 in $1"
  else
    echo "FAIL  decay: #$2 expected in $1"
    fail=1
  fi
}
assert_bucket agent_ready_stale       9002
assert_bucket agent_ready_invalidated 9003
assert_bucket agent_ready_invalidated 9004
assert_bucket agent_ready_invalidated 9005
assert_bucket agent_ready_invalidated 9007
assert_bucket agent_ready_invalidated 9008
# #9001 is fresh — must NOT appear in either decay bucket
if printf '%s' "$decay_scan" | jq -e \
    '(.buckets.agent_ready_stale + .buckets.agent_ready_invalidated) | any(.number == 9001)' >/dev/null; then
  echo "FAIL  decay: #9001 (fresh) must not be flagged"
  fail=1
else
  echo "PASS  decay: #9001 (fresh) not flagged"
fi
# #9006 has a trusted older marker + forged newer marker — trusted must win,
# so it must NOT appear in either decay bucket
if printf '%s' "$decay_scan" | jq -e \
    '(.buckets.agent_ready_stale + .buckets.agent_ready_invalidated) | any(.number == 9006)' >/dev/null; then
  echo "FAIL  decay: #9006 (trusted-older + untrusted-newer) must not be flagged"
  fail=1
else
  echo "PASS  decay: #9006 (trusted-older + untrusted-newer) not flagged"
fi

exit $fail
