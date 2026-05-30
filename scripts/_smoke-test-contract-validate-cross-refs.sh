#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-validate-cross-refs.sh — Contract test for
# docs/contracts/validate-cross-refs.contract.md. Asserts VCR-1..VCR-2
# against scripts/validate-cross-refs.sh. VCR-1 runs the validator
# against the live repo root (must be CONSISTENT). VCR-2 builds a temp
# project-dir fixture with a malformed dep entry and asserts the
# ✗-warning + non-zero exit. Both cases use provides-only / requires-only
# specs to dodge the documented Check-3 BSD/macOS-sed `\|` quirk (see
# the contract's Invariants and sync-contracts SC-7). Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-cross-refs.sh"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VCR-1 — live repo root is CONSISTENT (exit 0, summary + Check-4 green)
out=$(bash "$VALIDATOR" "$ROOT" 2>&1); rc=$?
if [ "$rc" = 0 ] \
  && echo "$out" | grep -q "CONSISTENT: All cross-reference checks passed." \
  && echo "$out" | grep -q "All frontmatter dep notations are well-formed"; then
  pass VCR-1
else
  fail_case VCR-1 "rc=$rc out=$out"
fi

# VCR-2 — temp fixture with a malformed dep entry → exit 1, distinct ✗ warning.
# Requires-only spec (no provides block) sidesteps the Check-3 BSD-sed bleed.
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/docs/specs"
cat > "$FIXTURE/docs/specs/bad.spec.md" <<'EOF'
---
name: bad
status: active
owner: bob
requires:
  - definitions/unsuffixed
---

# bad

Fixture spec with one malformed (missing-.md-suffix) dep notation.
EOF

out=$(bash "$VALIDATOR" "$FIXTURE" 2>&1); rc=$?
if [ "$rc" = 1 ] \
  && echo "$out" | grep -q 'bad.spec.md: requires entry "definitions/unsuffixed" looks like a path but lacks .md suffix' \
  && echo "$out" | grep -q "ISSUES FOUND:"; then
  pass VCR-2
else
  fail_case VCR-2 "rc=$rc out=$out"
fi

[ "$fail" = 0 ] && echo "validate-cross-refs contract: ALL PASS" || exit 1
