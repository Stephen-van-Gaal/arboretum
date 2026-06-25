#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-validate-cli-contract.sh — exercises validate-cli-contract.sh
# against the 6 fixtures under tests/contracts/cli/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-cli-contract.sh"
FIXTURES="$REPO_ROOT/tests/contracts/cli"

[ -x "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found or not executable" >&2; exit 1; }
[ -d "$FIXTURES" ]  || { echo "FAIL: $FIXTURES dir missing" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; fail=1; }

# Case 1: good fixture passes
if bash "$VALIDATOR" "$FIXTURES/good-001.cli-contract.md" >/dev/null 2>&1; then
  pass "case 1 — good fixture exits 0"
else
  fail_case "case 1 — good fixture should exit 0"
fi

# Cases 2-6: malformed fixtures fail
for bad in bad-missing-frontmatter-field bad-invalid-invoker-type \
           bad-missing-body-section bad-empty-test-surface bad-malformed-version; do
  if bash "$VALIDATOR" "$FIXTURES/$bad.cli-contract.md" >/dev/null 2>&1; then
    fail_case "case for $bad — should have exited non-zero"
  else
    pass "case for $bad — exits non-zero"
  fi
done

[ $fail -eq 0 ] && echo "All validate-cli-contract smoke cases passed." || exit 1
