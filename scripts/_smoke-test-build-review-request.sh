#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-build-review-request.sh — unit test for scripts/build-review-request.sh
# (#791 D2). The ReviewRequest is the context-parameterized request the pipeline stage
# hands the dispatcher: {altitude, artifact, base, brief} (section-dispatch element 1).
# Picked up by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/build-review-request.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# BRR-1 — emits a JSON object carrying all four request dimensions.
out="$(bash "$PROBE" --altitude finish --artifact diff --base main --brief - <<<'review the diff')"; rc=$?
if [ "$rc" = 0 ]; then
  shape="$(printf '%s' "$out" | jq -r '[.altitude, .artifact, .base, .brief] | @tsv')"
  [ "$shape" = "$(printf 'finish\tdiff\tmain\treview the diff')" ] && pass BRR-1 || fail_case BRR-1 "$shape"
else fail_case BRR-1 "rc=$rc out=$out"; fi

# BRR-2 — brief defaults to empty string when --brief is omitted (still a valid object).
out2="$(bash "$PROBE" --altitude design --artifact doc --base HEAD~1)"
b2="$(printf '%s' "$out2" | jq -r '.brief')"
[ "$b2" = "" ] && pass BRR-2 || fail_case BRR-2 "brief=$b2"

# BRR-3 — altitude outside {design,build,finish} → exit 2.
bash "$PROBE" --altitude deploy --artifact diff --base main >/dev/null 2>&1
[ "$?" = 2 ] && pass BRR-3 || fail_case BRR-3 "expected exit 2 on bad altitude"

# BRR-4 — artifact outside {doc,diff,tree} → exit 2.
bash "$PROBE" --altitude finish --artifact blob --base main >/dev/null 2>&1
[ "$?" = 2 ] && pass BRR-4 || fail_case BRR-4 "expected exit 2 on bad artifact"

# BRR-5 — missing --base → exit 2.
bash "$PROBE" --altitude finish --artifact diff >/dev/null 2>&1
[ "$?" = 2 ] && pass BRR-5 || fail_case BRR-5 "expected exit 2 on missing base"

[ "$fail" = 0 ] && echo "build-review-request: ALL PASS" || exit 1
