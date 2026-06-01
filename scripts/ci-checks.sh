#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-checks.sh — canonical check entrypoint. Run by the pre-PR local gate
# (skills/finish) and, once #206 merges, by .github/workflows/ci.yml — so the
# local gate and CI cannot drift. Exit 0 only if all blocking checks pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0

echo "=== ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  find scripts .claude/hooks skills -name '*.sh' ! -path '*/_archived/*' \
    -exec shellcheck --severity=warning {} + || fail=1
elif [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
  echo "FAIL: shellcheck is required but was not found on PATH" >&2
  fail=1
else
  echo "SKIP: shellcheck not found on PATH (set REQUIRE_SHELLCHECK=1 to require it)"
fi

echo "=== Smoke tests ==="
for f in scripts/_smoke-test-*.sh; do
  [[ "$f" == *"_smoke-test-ci-checks.sh" ]] && continue  # skip self-referential meta-test
  echo "--- $f ---"
  bash "$f" || fail=1
done

echo "=== Cross-reference validation ==="
bash scripts/validate-cross-refs.sh || fail=1

echo "=== Contract coverage validation ==="
bash scripts/validate-coverage-manifest.sh || fail=1

echo "=== Health check (non-blocking) ==="
bash scripts/health-check.sh "$ROOT" || echo "(health-check reported issues — non-blocking)"

echo "=== Version bump check ==="
bash scripts/check-version-bump.sh || fail=1

exit $fail
