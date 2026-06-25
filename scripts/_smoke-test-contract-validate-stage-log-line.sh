#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-validate-stage-log-line.sh — Contract test for
# docs/contracts/validate-stage-log-line.contract.md. Asserts VSL-1..VSL-6
# against scripts/validate-stage-log-line.sh by reusing the existing S9
# good/bad fixtures under tests/contracts/fixtures/. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-stage-log-line.sh"
FIX="$ROOT/tests/contracts/fixtures"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VSL-1 — good fixture accepted (exit 0, no S9-DRIFT)
bash "$VALIDATOR" "$FIX/log-stage-comment-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S9-DRIFT:" "$ERR"; then pass VSL-1; else fail_case VSL-1 "rc=$rc err=$(cat "$ERR")"; fi

# VSL-2 — bad marker → exit 1, S9-5 missing marker
bash "$VALIDATOR" "$FIX/log-stage-comment-bad-marker.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S9-DRIFT:" "$ERR" && grep -q "S9-5: missing marker" "$ERR"; then pass VSL-2; else fail_case VSL-2 "rc=$rc err=$(cat "$ERR")"; fi

# VSL-3 — bad timestamp → exit 1, S9-5 timestamp
bash "$VALIDATOR" "$FIX/log-stage-comment-bad-timestamp.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S9-5: timestamp" "$ERR"; then pass VSL-3; else fail_case VSL-3 "rc=$rc err=$(cat "$ERR")"; fi

# VSL-4 — bad action → exit 1, S9-2 action
bash "$VALIDATOR" "$FIX/log-stage-comment-bad-action.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S9-2: action" "$ERR"; then pass VSL-4; else fail_case VSL-4 "rc=$rc err=$(cat "$ERR")"; fi

# VSL-5 — bad quoting → exit 1, S9-7
bash "$VALIDATOR" "$FIX/log-stage-comment-bad-quoting.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S9-7:" "$ERR"; then pass VSL-5; else fail_case VSL-5 "rc=$rc err=$(cat "$ERR")"; fi

# VSL-6 — invocation error (non-existent path) → exit 2, no S9-DRIFT
bash "$VALIDATOR" "$FIX/no-such-log-comment-xyzzy.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 2 ] && grep -q "file not found" "$ERR" && ! grep -q "S9-DRIFT:" "$ERR"; then pass VSL-6; else fail_case VSL-6 "rc=$rc err=$(cat "$ERR")"; fi

[ "$fail" = 0 ] && echo "validate-stage-log-line contract: ALL PASS" || exit 1
