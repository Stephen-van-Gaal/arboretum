#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-validate-test-surface.sh — Contract test for
# docs/contracts/validate-test-surface.contract.md. Asserts VTS-1..VTS-6
# against scripts/validate-test-surface.sh by reusing the existing S3-6
# good/bad fixtures under tests/contracts/fixtures/. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-test-surface.sh"
FIX="$ROOT/tests/contracts/fixtures"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VTS-1 — good pair accepted (exit 0, no S3-6 summary)
bash "$VALIDATOR" "$FIX/design-with-test-surface.md" "$FIX/test-surface-list-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S3-6:" "$ERR"; then pass VTS-1; else fail_case VTS-1 "rc=$rc err=$(cat "$ERR")"; fi

# VTS-2 — bad pair (no block + non-empty list) → exit 1, S3-6 summary + 'spec lacks test-surface-changes block'
bash "$VALIDATOR" "$FIX/design-good.md" "$FIX/test-surface-list-bad.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S3-6:" "$ERR" && grep -q "spec lacks test-surface-changes block" "$ERR"; then pass VTS-2; else fail_case VTS-2 "rc=$rc err=$(cat "$ERR")"; fi

# VTS-3 — metachar near-miss → exit 1, names the unlisted file
bash "$VALIDATOR" "$FIX/design-with-test-surface-metachar.md" "$FIX/test-surface-list-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "test file tests/example/foo_test.sh changed but not listed" "$ERR"; then pass VTS-3; else fail_case VTS-3 "rc=$rc err=$(cat "$ERR")"; fi

# VTS-4 — YAML-quoted entry accepted → exit 0
bash "$VALIDATOR" "$FIX/design-with-test-surface-quoted.md" "$FIX/test-surface-list-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S3-6:" "$ERR"; then pass VTS-4; else fail_case VTS-4 "rc=$rc err=$(cat "$ERR")"; fi

# VTS-5 — reason-bearing entry accepted → exit 0
bash "$VALIDATOR" "$FIX/design-with-test-surface-reasons.md" "$FIX/test-surface-list-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S3-6:" "$ERR"; then pass VTS-5; else fail_case VTS-5 "rc=$rc err=$(cat "$ERR")"; fi

# VTS-6 — invocation error (non-existent spec) → exit 2, 'S3-6: spec not found', no '<N> issue(s)' summary
bash "$VALIDATOR" "$FIX/does-not-exist-xyzzy.md" "$FIX/test-surface-list-good.txt" 2>"$ERR"; rc=$?
if [ "$rc" = 2 ] && grep -q "S3-6: spec not found" "$ERR" && ! grep -q "issue(s) in" "$ERR"; then pass VTS-6; else fail_case VTS-6 "rc=$rc err=$(cat "$ERR")"; fi

[ "$fail" = 0 ] && echo "validate-test-surface contract: ALL PASS" || exit 1
