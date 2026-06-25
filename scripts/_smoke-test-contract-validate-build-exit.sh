#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-validate-build-exit.sh — Contract test for
# docs/contracts/validate-build-exit.contract.md. Asserts VBE-1..VBE-5
# against scripts/validate-build-exit.sh by reusing the existing S3
# good/bad fixtures under tests/contracts/fixtures/. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-build-exit.sh"
FIX="$ROOT/tests/contracts/fixtures"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VBE-1 — good success line + its spec accepted (exit 0, no S3-DRIFT)
bash "$VALIDATOR" "$FIX/build-exit-success-good.txt" "$FIX/design-good.md" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S3-DRIFT:" "$ERR"; then pass VBE-1; else fail_case VBE-1 "rc=$rc err=$(cat "$ERR")"; fi

# VBE-2 — missing exit-status → exit 1, S3-1
bash "$VALIDATOR" "$FIX/build-exit-no-status.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S3-DRIFT:" "$ERR" && grep -q "S3-1: log line missing 'exit-status:' field" "$ERR"; then pass VBE-2; else fail_case VBE-2 "rc=$rc err=$(cat "$ERR")"; fi

# VBE-3 — out-of-enum exit-status → exit 1, S3-2
bash "$VALIDATOR" "$FIX/build-exit-bad-status-enum.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S3-2: exit-status value not in" "$ERR"; then pass VBE-3; else fail_case VBE-3 "rc=$rc err=$(cat "$ERR")"; fi

# VBE-4 — escape-hatch without trigger block in spec → exit 1, S3-7
bash "$VALIDATOR" "$FIX/build-exit-escape-hatch-no-trigger.txt" "$FIX/design-good.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S3-7: design spec missing 'escape-hatch:' block" "$ERR"; then pass VBE-4; else fail_case VBE-4 "rc=$rc err=$(cat "$ERR")"; fi

# VBE-5 — invocation error (non-existent log file) → exit 2, no S3-DRIFT
bash "$VALIDATOR" "$FIX/no-such-build-log-xyzzy.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 2 ] && grep -q "log file not found" "$ERR" && ! grep -q "S3-DRIFT:" "$ERR"; then pass VBE-5; else fail_case VBE-5 "rc=$rc err=$(cat "$ERR")"; fi

[ "$fail" = 0 ] && echo "validate-build-exit contract: ALL PASS" || exit 1
