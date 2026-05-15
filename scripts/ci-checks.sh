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
find scripts .claude/hooks skills -name '*.sh' ! -path '*/_archived/*' \
  -exec shellcheck --severity=warning {} + || fail=1

echo "=== Smoke tests ==="
for f in scripts/_smoke-test-*.sh; do
  [[ "$f" == *"_smoke-test-ci-checks.sh" ]] && continue  # skip self-referential meta-test
  echo "--- $f ---"
  bash "$f" || fail=1
done

echo "=== Cross-reference validation ==="
bash scripts/validate-cross-refs.sh || fail=1

echo "=== Health check (non-blocking) ==="
bash scripts/health-check.sh "$ROOT" || echo "(health-check reported issues — non-blocking)"

exit $fail
