#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-validate-design-spec.sh — Contract test for
# docs/contracts/validate-design-spec.contract.md. Asserts VDS-1..VDS-5
# against scripts/validate-design-spec.sh by reusing the existing S2
# good/bad fixtures under tests/contracts/fixtures/. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-design-spec.sh"
FIX="$ROOT/tests/contracts/fixtures"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VDS-1 — good fixture accepted (exit 0, no S2-DRIFT)
bash "$VALIDATOR" "$FIX/design-good.md" >/dev/null 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S2-DRIFT:" "$ERR"; then pass VDS-1; else fail_case VDS-1 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-2 — missing triage → exit 1, S2-DRIFT + 'triage: missing'
bash "$VALIDATOR" "$FIX/design-missing-triage.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S2-DRIFT:" "$ERR" && grep -q "triage: missing" "$ERR"; then pass VDS-2; else fail_case VDS-2 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-3 — out-of-enum implementation-mode → exit 1, 'implementation-mode: not in'
bash "$VALIDATOR" "$FIX/design-bad-enum-implementation-mode.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "implementation-mode: not in" "$ERR"; then pass VDS-3; else fail_case VDS-3 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-4 — plan path missing file → exit 1, 'plan: file not found'
bash "$VALIDATOR" "$FIX/design-plan-missing-file.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "plan: file not found" "$ERR"; then pass VDS-4; else fail_case VDS-4 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-5 — invocation error (non-existent path) → exit 2, no S2-DRIFT
bash "$VALIDATOR" "$FIX/does-not-exist-xyzzy.md" 2>"$ERR"; rc=$?
if [ "$rc" = 2 ] && grep -q "file not found" "$ERR" && ! grep -q "S2-DRIFT:" "$ERR"; then pass VDS-5; else fail_case VDS-5 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-6 — missing yaml-lite helper → exit 2, clear invocation diagnostic, no S2-DRIFT
MISSING_HELPER=$(mktemp -d)
mkdir -p "$MISSING_HELPER/scripts"
cp "$VALIDATOR" "$MISSING_HELPER/scripts/validate-design-spec.sh"
bash "$MISSING_HELPER/scripts/validate-design-spec.sh" "$FIX/design-good.md" 2>"$ERR"; rc=$?
rm -rf "$MISSING_HELPER"
if [ "$rc" = 2 ] && grep -q "yaml-lite helper not found" "$ERR" && ! grep -q "S2-DRIFT:" "$ERR"; then pass VDS-6; else fail_case VDS-6 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-7 — kind: shaping with only related-issue → exit 0, no S2-DRIFT (#692)
bash "$VALIDATOR" "$FIX/design-shaping-good.md" >/dev/null 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S2-DRIFT:" "$ERR"; then pass VDS-7; else fail_case VDS-7 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-8 — kind: shaping missing related-issue → exit 1, 'related-issue: missing' (#692)
bash "$VALIDATOR" "$FIX/design-shaping-missing-related-issue.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "S2-DRIFT:" "$ERR" && grep -q "related-issue: missing" "$ERR"; then pass VDS-8; else fail_case VDS-8 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-9 — kind: shaping ignores stray build fields → exit 0 (#692)
bash "$VALIDATOR" "$FIX/design-shaping-with-build-fields.md" >/dev/null 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "S2-DRIFT:" "$ERR"; then pass VDS-9; else fail_case VDS-9 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-10 — kind out of enum → exit 1, 'kind: not in' (#692)
bash "$VALIDATOR" "$FIX/design-bad-kind.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "kind: not in" "$ERR"; then pass VDS-10; else fail_case VDS-10 "rc=$rc err=$(cat "$ERR")"; fi

# VDS-11 — mapping-valued kind → exit 1, rejected as non-scalar (fail-safe, not
# read as absent ⇒ buildable). (#692, Codex review)
bash "$VALIDATOR" "$FIX/design-mapping-kind.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "kind: must be a scalar" "$ERR"; then pass VDS-11; else fail_case VDS-11 "rc=$rc err=$(cat "$ERR")"; fi

[ "$fail" = 0 ] && echo "validate-design-spec contract: ALL PASS" || exit 1
