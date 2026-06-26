#!/usr/bin/env bash
# owner: test-infrastructure
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-adopter-ci-boundary.sh — regression checks for the adopter product
# test boundary. Arboretum ci-checks/health may be advisory framework checks, but
# initialized adopter repos must not satisfy product-test gates by falling back to
# ci-checks when their declared default-command is invalid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0

expect_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -qF "$needle" "$file"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    echo "  missing: $needle" >&2
    fail=1
  fi
}

expect_absent() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -qF "$needle" "$file"; then
    echo "FAIL: $label" >&2
    echo "  forbidden: $needle" >&2
    fail=1
  else
    echo "PASS: $label"
  fi
}

expect_contains \
  docs/contracts/test-infrastructure.contract.md \
  "A present but invalid declaration MUST fail closed" \
  "contract says present-invalid declarations fail closed"

expect_absent \
  docs/contracts/test-infrastructure.contract.md \
  "bash scripts/ci-checks.sh convention" \
  "contract no longer treats ci-checks as the product-test fallback"

expect_contains \
  skills/build/SKILL.md \
  "the gate fails closed; do not fall back to scripts/ci-checks.sh" \
  "/build fails closed for present-invalid testing declarations"

expect_absent \
  skills/build/SKILL.md \
  'echo "ERROR: $TEST_SPEC is present but invalid; the gate fails closed; do not fall back to `scripts/ci-checks.sh`.' \
  "/build diagnostic does not command-substitute ci-checks path"

expect_absent \
  skills/build/SKILL.md \
  "falling back to legacy discovery" \
  "/build no longer falls back after an invalid present spec"

expect_contains \
  skills/finish/SKILL.md \
  "do not fall back to scripts/ci-checks.sh" \
  "/finish refuses ci-checks fallback for present-invalid declarations"

expect_absent \
  skills/finish/SKILL.md \
  'echo "ERROR: $TEST_SPEC is present but invalid; do not fall back to `scripts/ci-checks.sh`.' \
  "/finish diagnostic does not command-substitute ci-checks path"

expect_absent \
  skills/finish/SKILL.md \
  "falling back — fix the declaration" \
  "/finish no longer warns and falls back after invalid present spec"

expect_contains \
  skills/design/SKILL.md \
  "if the spec file is present but the reader fails, fail the coverage-baseline gate" \
  "/design coverage-baseline fails closed for invalid present specs"

expect_absent \
  skills/design/SKILL.md \
  'fall back to the existing discovery — the `bash scripts/ci-checks.sh` convention' \
  "/design no longer names ci-checks as fallback discovery"

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi

echo "SMOKE TEST PASSED"
