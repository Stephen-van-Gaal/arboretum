#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-validate-cli-contract.sh — Contract test for
# docs/contracts/validate-cli-contract.contract.md. Asserts VCC-1..VCC-7
# against scripts/validate-cli-contract.sh by reusing the existing
# good/bad CLI-contract fixtures under tests/contracts/cli/. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-cli-contract.sh"
FIX="$ROOT/tests/contracts/cli"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VCC-1 — good fixture accepted (exit 0, no CLI-CONTRACT-DRIFT)
bash "$VALIDATOR" "$FIX/good-001.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "CLI-CONTRACT-DRIFT:" "$ERR"; then pass VCC-1; else fail_case VCC-1 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-2 — missing frontmatter field → exit 1, DRIFT + 'missing required frontmatter field: version'
bash "$VALIDATOR" "$FIX/bad-missing-frontmatter-field.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "CLI-CONTRACT-DRIFT:" "$ERR" && grep -q "missing required frontmatter field: version" "$ERR"; then pass VCC-2; else fail_case VCC-2 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-3 — invalid invoker type → exit 1, 'not in closed enum'
bash "$VALIDATOR" "$FIX/bad-invalid-invoker-type.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "not in closed enum" "$ERR"; then pass VCC-3; else fail_case VCC-3 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-4 — malformed version → exit 1, 'version must be semver-light'
bash "$VALIDATOR" "$FIX/bad-malformed-version.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "version must be semver-light" "$ERR"; then pass VCC-4; else fail_case VCC-4 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-5 — missing body section → exit 1, 'missing required body section'
bash "$VALIDATOR" "$FIX/bad-missing-body-section.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "missing required body section" "$ERR"; then pass VCC-5; else fail_case VCC-5 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-6 — empty test surface → exit 1, 'has no bullet-list assertions'
bash "$VALIDATOR" "$FIX/bad-empty-test-surface.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 1 ] && grep -q "## Test surface has no bullet-list assertions" "$ERR"; then pass VCC-6; else fail_case VCC-6 "rc=$rc err=$(cat "$ERR")"; fi

# VCC-7 — invocation error (non-existent path) → exit 2, 'Not a file:', no CLI-CONTRACT-DRIFT
bash "$VALIDATOR" "$FIX/does-not-exist-xyzzy.cli-contract.md" 2>"$ERR"; rc=$?
if [ "$rc" = 2 ] && grep -q "Not a file:" "$ERR" && ! grep -q "CLI-CONTRACT-DRIFT:" "$ERR"; then pass VCC-7; else fail_case VCC-7 "rc=$rc err=$(cat "$ERR")"; fi

[ "$fail" = 0 ] && echo "validate-cli-contract contract: ALL PASS" || exit 1
