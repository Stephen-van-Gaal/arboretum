#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-checks.sh — canonical check entrypoint. Run by the pre-PR local gate
# (skills/finish) and, once #206 merges, by .github/workflows/ci.yml — so the
# local gate and CI cannot drift. Exit 0 only if all blocking checks pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0

is_plugin_root() {
  [ -d skills ] \
    && [ -d hooks ] \
    && [ -d docs/contracts ] \
    && [ -d tests/contracts ] \
    && [ -d scripts/_fixtures/roadmap ] \
    && [ -f .github/ISSUE_TEMPLATE/agent-ready.md ]
}

smoke_test_applicable() {
  local f="$1"
  local owner_line owner_name scope_line scope
  local owner_re scope_re

  if is_plugin_root; then
    return 0
  fi

  scope_re='^# scope: (plugin-only|consumer|any)$'
  scope_line="$(sed -n '1,8{/^# scope: /p;}' "$f" | head -1)"
  if [[ "$scope_line" =~ $scope_re ]]; then
    scope="${BASH_REMATCH[1]}"
    case "$scope" in
      consumer|any)
        return 0
        ;;
      plugin-only)
        echo "SKIP: $f (scope '$scope' is not applicable in this root)"
        return 1
        ;;
    esac
  fi

  owner_line="$(sed -n '2p' "$f")"
  owner_re='^# owner: ([a-z][a-z0-9-]+)$'
  if [[ "$owner_line" =~ $owner_re ]]; then
    owner_name="${BASH_REMATCH[1]}"
    if [ ! -f "docs/specs/$owner_name.spec.md" ]; then
      echo "SKIP: $f (owner '$owner_name' spec is not installed in this root)"
      return 1
    fi
  fi

  echo "SKIP: $f (no consumer-applicable scope declared)"
  return 1
}

echo "=== ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_roots=()
  for root in scripts .claude/hooks skills; do
    [ -d "$root" ] && shellcheck_roots+=("$root")
  done

  if [ "${#shellcheck_roots[@]}" -eq 0 ]; then
    echo "SKIP: no ShellCheck roots found"
  else
    find "${shellcheck_roots[@]}" -name '*.sh' ! -path '*/_archived/*' \
      -exec shellcheck --severity=warning {} + || fail=1
  fi
elif [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
  echo "FAIL: shellcheck is required but was not found on PATH" >&2
  fail=1
else
  echo "SKIP: shellcheck not found on PATH (set REQUIRE_SHELLCHECK=1 to require it)"
fi

echo "=== Smoke tests ==="
for f in scripts/_smoke-test-*.sh; do
  [[ "$f" == *"_smoke-test-ci-checks.sh" ]] && continue  # skip self-referential meta-test
  smoke_test_applicable "$f" || continue
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
