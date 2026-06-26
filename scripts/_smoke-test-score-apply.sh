#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-score-apply.sh — dry-run contract tests for score-apply.sh.
# Asserts on PLAN/NEEDS-CONFIRM/NOMINATE output; performs no live mutation.
# Live-mode guards (label fetch, body-sha revalidation, evidence comment) are
# tested via a mock harness that stubs the tracker functions in a temp lib.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SA="$SCRIPT_DIR/roadmap/score-apply.sh"; fail=0
tmpc="$(mktemp)"
cat > "$tmpc" <<'EOF'
{"5":{"disposition":"delete","class":"work-unit","value_description":"obsolete"},
 "8":{"disposition":"delete","class":"orchestrator","value_description":"epic"},
 "6":{"disposition":"decompose","class":"orchestrator"},
 "7":{"disposition":"delete","value_description":"null-class-issue"}}
EOF
out="$(bash "$SA" --cache "$tmpc" --dry-run)"
echo "$out" | grep -E 'close .*#5|#5 .*delete' >/dev/null && echo "ok - #5 delete planned" || { echo "FAIL #5"; fail=1; }
echo "$out" | grep -E 'NEEDS-CONFIRM' | grep -q '#8' && echo "ok - epic #8 needs-confirm" || { echo "FAIL epic guard"; fail=1; }
echo "$out" | grep -E '#6' | grep -qi 'nominate' && echo "ok - decompose nominate-only" || { echo "FAIL decompose"; fail=1; }
# Null/missing class must NOT generate a PLAN — allowlist blocks it.
echo "$out" | grep -E 'NEEDS-CONFIRM' | grep -q '#7' && echo "ok - null-class #7 not planned (NEEDS-CONFIRM)" || { echo "FAIL null-class guard — #7 was not routed to NEEDS-CONFIRM"; fail=1; }
echo "$out" | grep -qE 'PLAN.*#7|close.*#7' && { echo "FAIL null-class #7 should not be PLAN"; fail=1; } || true
rm -f "$tmpc"

# --- Live-mode guard tests via mock harness ---
# Set up a temp directory with a mock lib.sh so we can test the non-dry-run path
# without touching a real tracker. MOCK_* env vars control stub behaviour.
mock_dir="$(mktemp -d)"
cp "$SCRIPT_DIR/roadmap/score-apply.sh" "$mock_dir/score-apply.sh"

# Write a minimal mock lib.sh covering the functions score-apply.sh calls.
# MOCK_SHOW_BEHAVIOR: ok (default — returns clean issue), fail, epic, stale
# MOCK_COMMENT_BEHAVIOR: ok (default), fail
cat > "$mock_dir/lib.sh" << 'MOCKLIB'
# shellcheck shell=bash
roadmap_project_root() { echo "/tmp/mock-project"; }
roadmap_backend()      { echo "github"; }
roadmap_require_backend() { return 0; }
roadmap_tracker_issue_show() {
  # build a body whose sha matches MOCK_BODY_SHA (defaults to a stable sha of "test body")
  local default_body="test body"
  local body="${MOCK_BODY:-$default_body}"
  case "${MOCK_SHOW_BEHAVIOR:-ok}" in
    fail)   return 1 ;;
    epic)   printf '{"labels":[{"name":"type:epic"}],"body":"%s","state":"open"}\n' "$body" ;;
    closed) printf '{"labels":[],"body":"%s","state":"closed"}\n' "$body" ;;
    *)      printf '{"labels":[],"body":"%s","state":"open"}\n' "$body" ;;
  esac
}
roadmap_tracker_issue_comment() {
  case "${MOCK_COMMENT_BEHAVIOR:-ok}" in
    fail) return 1 ;;
    *)    return 0 ;;
  esac
}
roadmap_tracker_issue_close() {
  printf 'MOCK_CLOSED:%s\n' "$1"
  return 0
}
roadmap_pulse_update_field() { return 0; }
MOCKLIB

# Compute the sha that matches the mock body so we can build matching caches.
mock_body="test body"
mock_sha="$(printf '%s' "$mock_body" | shasum -a 256 | cut -c1-12)"

# Finding 2: label-fetch failure → issue is skipped with NEEDS-CONFIRM, not closed.
tmpc2="$(mktemp)"
printf '{"42":{"disposition":"delete","class":"work-unit","value_description":"test","body_sha":"%s"}}\n' "$mock_sha" > "$tmpc2"
out2="$(MOCK_SHOW_BEHAVIOR=fail bash "$mock_dir/score-apply.sh" --cache "$tmpc2" 2>&1)"
echo "$out2" | grep -qi 'NEEDS-CONFIRM' && echo "ok - label fetch failure → NEEDS-CONFIRM (Finding 2)" \
  || { echo "FAIL - label fetch failure should emit NEEDS-CONFIRM"; fail=1; }
echo "$out2" | grep -qi 'MOCK_CLOSED' && { echo "FAIL - label fetch failure should not close issue"; fail=1; } \
  || echo "ok - label fetch failure → issue not closed (Finding 2)"
rm -f "$tmpc2"

# Finding 4: evidence comment failure → close is skipped.
tmpc4="$(mktemp)"
printf '{"43":{"disposition":"delete","class":"work-unit","value_description":"test","body_sha":"%s"}}\n' "$mock_sha" > "$tmpc4"
out4="$(MOCK_COMMENT_BEHAVIOR=fail bash "$mock_dir/score-apply.sh" --cache "$tmpc4" 2>&1)"
echo "$out4" | grep -qi 'NEEDS-CONFIRM' && echo "ok - comment failure → NEEDS-CONFIRM (Finding 4)" \
  || { echo "FAIL - comment failure should emit NEEDS-CONFIRM"; fail=1; }
echo "$out4" | grep -qi 'MOCK_CLOSED' && { echo "FAIL - comment failure should not close issue"; fail=1; } \
  || echo "ok - comment failure → issue not closed (Finding 4)"
rm -f "$tmpc4"

# Finding 7: body changed since scoring → close is skipped with cache-stale message.
tmpc7="$(mktemp)"
# Cache has a stale sha (all zeros) that won't match the live "test body" sha.
printf '{"44":{"disposition":"delete","class":"work-unit","value_description":"test","body_sha":"000000000000"}}\n' > "$tmpc7"
out7="$(bash "$mock_dir/score-apply.sh" --cache "$tmpc7" 2>&1)"
echo "$out7" | grep -qi 'stale\|re-score' && echo "ok - stale body → cache-stale message (Finding 7)" \
  || { echo "FAIL - stale body should emit cache-stale message"; fail=1; }
echo "$out7" | grep -qi 'MOCK_CLOSED' && { echo "FAIL - stale body should not close issue"; fail=1; } \
  || echo "ok - stale body → issue not closed (Finding 7)"
rm -f "$tmpc7"

# Finding 2 (Codex): body_sha hashing must use the printf '%s' convention (no trailing
# newline). An UNCHANGED body must revalidate as NOT stale so the delete proceeds.
# Before the fix, piping jq -r directly to shasum hashed "body\n" and always mismatched.
tmpc_f2="$(mktemp)"
printf '{"45":{"disposition":"delete","class":"work-unit","value_description":"test","body_sha":"%s"}}\n' "$mock_sha" > "$tmpc_f2"
out_f2="$(bash "$mock_dir/score-apply.sh" --cache "$tmpc_f2" 2>&1)"
# score-apply.sh redirects roadmap_tracker_issue_close stdout to /dev/null; check the
# "✓ closed #N" echo that score-apply.sh itself emits on success.
echo "$out_f2" | grep -qE '(closed|✓).*45|45.*(closed|✓)' && echo "ok - unchanged body → not stale → delete proceeds (Finding 2 Codex)" \
  || { echo "FAIL - unchanged body should allow delete (body_sha hash mismatch?). Output: $out_f2"; fail=1; }
echo "$out_f2" | grep -qi 'stale\|re-score' && { echo "FAIL - unchanged body should not be marked stale"; fail=1; } \
  || echo "ok - unchanged body → not marked stale (Finding 2 Codex)"
rm -f "$tmpc_f2"

# Codex R3-F2: issue already closed between scoring and apply → skip, no close attempt.
tmpc_r3f2="$(mktemp)"
printf '{"46":{"disposition":"delete","class":"work-unit","value_description":"test","body_sha":"%s"}}\n' "$mock_sha" > "$tmpc_r3f2"
out_r3f2="$(MOCK_SHOW_BEHAVIOR=closed bash "$mock_dir/score-apply.sh" --cache "$tmpc_r3f2" 2>&1)"
echo "$out_r3f2" | grep -qi 'skip.*already.closed\|already.closed' \
  && echo "ok - already-closed → skip message (Codex R3-F2)" \
  || { echo "FAIL - already-closed should emit skip message. Output: $out_r3f2"; fail=1; }
echo "$out_r3f2" | grep -qi 'MOCK_CLOSED' \
  && { echo "FAIL - already-closed should not issue a close call"; fail=1; } \
  || echo "ok - already-closed → no close call (Codex R3-F2)"
rm -f "$tmpc_r3f2"

rm -rf "$mock_dir"
exit $fail
