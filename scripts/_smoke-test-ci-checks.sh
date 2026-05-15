#!/usr/bin/env bash
# owner: git-workflow-tooling
# _smoke-test-ci-checks.sh — assert ci-checks.sh exists, is executable, and
# emits a section header per check. Does not assert checks pass (that depends
# on repo state) — only that the entrypoint runs and reports structure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI="$SCRIPT_DIR/ci-checks.sh"
[ -x "$CI" ] || { echo "FAIL: ci-checks.sh missing or not executable" >&2; exit 1; }
out=$(bash "$CI" 2>&1 || true)
for section in "ShellCheck" "Smoke tests" "Cross-reference" "Health check"; do
  grep -qF "$section" <<< "$out" || {
    echo "FAIL: ci-checks.sh output missing section '$section'" >&2; exit 1; }
done
echo "PASS: ci-checks.sh runs and reports all 4 sections"
