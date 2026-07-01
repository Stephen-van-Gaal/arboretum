#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-read-autonomy-grant.sh — Contract checks for
# scripts/read-autonomy-grant.sh (the grant carriage resolver, #922).
#
# Uses AUTONOMY_GRANT_LABELS_OVERRIDE to inject a label set so the resolver is
# exercised without a live tracker (gh): the override stands in for the labels a
# `roadmap_tracker_issue_show --json labels` call would return.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/read-autonomy-grant.sh"
TMP="${TMPDIR:-/tmp}/autonomy-grant-smoke.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

run() {  # run <labels-override> [issue]
  local labels="$1"; local issue="${2:-917}"
  set +e
  AUTONOMY_GRANT_LABELS_OVERRIDE="$labels" bash "$HELPER" "$issue" >"$TMP/out" 2>"$TMP/err"
  printf '%s\n' "$?" >"$TMP/rc"
  set -e
}

# ── A labelled issue resolves to its tier ───────────────────────────
for tier in pause-at-land pause-at-merge auto-merge; do
  run "type:feature autonomy:$tier component:workflows"
  [ "$(cat "$TMP/rc")" = "0" ] || fail "labelled issue ($tier) should resolve" "$(cat "$TMP/err")"
  [ "$(cat "$TMP/out")" = "grant=$tier" ] || fail "expected grant=$tier" "$(cat "$TMP/out")"
done
ok "each autonomy:* tier resolves to its grant"

# ── No autonomy label → design-only (the absence default) ───────────
run "type:feature horizon:later component:workflows"
[ "$(cat "$TMP/rc")" = "0" ] || fail "unlabelled issue should resolve to design-only" "$(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "grant=design-only" ] || fail "expected grant=design-only" "$(cat "$TMP/out")"
ok "no autonomy label resolves to design-only"

# ── Empty label set → design-only ───────────────────────────────────
run ""
[ "$(cat "$TMP/rc")" = "0" ] || fail "empty labels should resolve to design-only" "$(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "grant=design-only" ] || fail "empty → design-only" "$(cat "$TMP/out")"
ok "empty label set resolves to design-only"

# ── Drift: two autonomy:* labels (the label is supposed to be exclusive) ──
run "autonomy:pause-at-merge autonomy:auto-merge"
[ "$(cat "$TMP/rc")" != "0" ] || fail "two autonomy:* labels must be flagged as drift"
grep -qi "exclusive\|multiple\|more than one" "$TMP/err" || fail "drift diagnostic should explain exclusivity" "$(cat "$TMP/err")"
ok "multiple autonomy:* labels are rejected as drift"

# ── Drift: an autonomy:* value outside the closed vocabulary ────────
run "autonomy:yolo"
[ "$(cat "$TMP/rc")" != "0" ] || fail "out-of-vocabulary autonomy label must be rejected"
grep -qi "vocabulary\|unknown\|invalid" "$TMP/err" || fail "diagnostic should name the bad value" "$(cat "$TMP/err")"
ok "out-of-vocabulary autonomy:* label is rejected"

# ── Bad invocation: missing issue arg ───────────────────────────────
set +e
AUTONOMY_GRANT_LABELS_OVERRIDE="autonomy:auto-merge" bash "$HELPER" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
[ "$rc" != "0" ] || fail "missing issue arg should fail"
ok "missing issue arg is rejected"

echo "read-autonomy-grant smoke: ALL PASS"
