#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-verify-agent-ready.sh — Contract test for
# docs/contracts/verify-agent-ready.contract.md. Asserts VAR-1..VAR-7
# against scripts/verify-agent-ready.sh.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-agent-ready.sh"
[ -f "$VERIFY" ] || { echo "FAIL: $VERIFY not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

sha12() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-12
}

write_issue() {
  local file="$1" number="$2" label="$3" body="$4" marker_date="$5" marker_sha="$6" assoc="$7"
  local labels_json="[]"
  if [ -n "$label" ]; then
    labels_json='[{"name":"agent-ready"}]'
  fi
  jq -n \
    --argjson number "$number" \
    --arg body "$body" \
    --argjson labels "$labels_json" \
    --arg marker_date "$marker_date" \
    --arg marker_sha "$marker_sha" \
    --arg assoc "$assoc" \
    '{
      number: $number,
      title: "Fixture issue",
      body: $body,
      labels: $labels,
      comments: [
        {
          createdAt: "2026-05-20T00:00:00Z",
          authorAssociation: $assoc,
          body: ("verified\n<!-- agent-prep:verified date=" + $marker_date + " body-sha=" + $marker_sha + " -->")
        }
      ]
    }' > "$file"
}

body="Fix the exact thing described here."
body_sha="$(sha12 "$body")"

# VAR-1 — ready issue exits 0 and emits controlled key=value lines.
ready="$TMP/ready.json"
write_issue "$ready" 101 yes "$body" "2026-05-20" "$body_sha" "OWNER"
out="$(bash "$VERIFY" --issue-file "$ready" --as-of 2026-05-22 2>"$TMP/ready.err")"; rc=$?
if [ "$rc" = 0 ] \
   && printf '%s\n' "$out" | grep -q '^status=ready$' \
   && printf '%s\n' "$out" | grep -q '^issue=101$' \
   && printf '%s\n' "$out" | grep -q "^body-sha=$body_sha$"; then
  pass VAR-1
else
  fail_case VAR-1 "rc=$rc out=$out err=$(cat "$TMP/ready.err")"
fi

# VAR-2 — missing agent-ready label is not ready.
missing_label="$TMP/missing-label.json"
write_issue "$missing_label" 102 "" "$body" "2026-05-20" "$body_sha" "OWNER"
out="$(bash "$VERIFY" --issue-file "$missing_label" --as-of 2026-05-22 2>"$TMP/missing-label.err")"; rc=$?
if [ "$rc" = 1 ] && grep -q 'reason=missing-agent-ready-label' "$TMP/missing-label.err"; then
  pass VAR-2
else
  fail_case VAR-2 "rc=$rc out=$out err=$(cat "$TMP/missing-label.err")"
fi

# VAR-3 — an untrusted marker is ignored.
untrusted="$TMP/untrusted.json"
write_issue "$untrusted" 103 yes "$body" "2026-05-20" "$body_sha" "NONE"
out="$(bash "$VERIFY" --issue-file "$untrusted" --as-of 2026-05-22 2>"$TMP/untrusted.err")"; rc=$?
if [ "$rc" = 1 ] && grep -q 'reason=missing-trusted-verification-marker' "$TMP/untrusted.err"; then
  pass VAR-3
else
  fail_case VAR-3 "rc=$rc out=$out err=$(cat "$TMP/untrusted.err")"
fi

# VAR-4 — body edits invalidate the marker.
edited="$TMP/edited.json"
write_issue "$edited" 104 yes "$body" "2026-05-20" "000000000000" "MEMBER"
out="$(bash "$VERIFY" --issue-file "$edited" --as-of 2026-05-22 2>"$TMP/edited.err")"; rc=$?
if [ "$rc" = 1 ] && grep -q 'reason=body-sha-mismatch' "$TMP/edited.err"; then
  pass VAR-4
else
  fail_case VAR-4 "rc=$rc out=$out err=$(cat "$TMP/edited.err")"
fi

# VAR-5 — verification older than seven days is stale.
stale="$TMP/stale.json"
write_issue "$stale" 105 yes "$body" "2026-05-01" "$body_sha" "COLLABORATOR"
out="$(bash "$VERIFY" --issue-file "$stale" --as-of 2026-05-22 2>"$TMP/stale.err")"; rc=$?
if [ "$rc" = 1 ] && grep -q 'reason=agent-ready-stale' "$TMP/stale.err"; then
  pass VAR-5
else
  fail_case VAR-5 "rc=$rc out=$out err=$(cat "$TMP/stale.err")"
fi

# VAR-6 — future verification dates are malformed rather than fresh.
future="$TMP/future.json"
write_issue "$future" 106 yes "$body" "2026-05-29" "$body_sha" "OWNER"
out="$(bash "$VERIFY" --issue-file "$future" --as-of 2026-05-22 2>"$TMP/future.err")"; rc=$?
if [ "$rc" = 1 ] && grep -q 'reason=malformed-verification-marker' "$TMP/future.err"; then
  pass VAR-6
else
  fail_case VAR-6 "rc=$rc out=$out err=$(cat "$TMP/future.err")"
fi

# VAR-7 — unknown arg exits 2.
bash "$VERIFY" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass VAR-7 || fail_case VAR-7 "rc=$rc"

[ "$fail" = 0 ] && echo "verify-agent-ready contract: ALL PASS" || exit 1
