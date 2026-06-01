#!/usr/bin/env bash
# owner: git-workflow-tooling
# _smoke-test-ci-checks.sh — assert ci-checks.sh exists, is executable, and
# emits a section header per check. Does not assert checks pass (that depends
# on repo state) — only that the entrypoint runs and reports structure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI="$SCRIPT_DIR/ci-checks.sh"
[ -x "$CI" ] || { echo "FAIL: ci-checks.sh missing or not executable" >&2; exit 1; }

TMP_DIRS=()
cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

new_tmp_dir() {
  local tmp
  tmp="$(mktemp -d)"
  TMP_DIRS+=("$tmp")
  echo "$tmp"
}

make_ci_fixture() {
  local tmp="$1"
  local repo="$tmp/repo"
  local bin="$tmp/bin"
  local tool

  mkdir -p "$bin" "$repo/scripts" "$repo/.claude/hooks" "$repo/skills"
  cp "$CI" "$repo/scripts/ci-checks.sh"
  chmod +x "$repo/scripts/ci-checks.sh"

  for tool in bash dirname find; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done

  for tool in \
    "_smoke-test-fixture.sh" \
    "validate-cross-refs.sh" \
    "validate-coverage-manifest.sh" \
    "health-check.sh" \
    "check-version-bump.sh"
  do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/$tool"
    chmod +x "$repo/scripts/$tool"
  done
}

run_ci_fixture() {
  local tmp="$1"
  PATH="$tmp/bin" "$(command -v bash)" "$tmp/repo/scripts/ci-checks.sh"
}

out=$(bash "$CI" 2>&1 || true)
for section in "ShellCheck" "Smoke tests" "Cross-reference" "Contract coverage" "Health check" "Version bump"; do
  grep -qF "$section" <<< "$out" || {
    echo "FAIL: ci-checks.sh output missing section '$section'" >&2; exit 1; }
done
echo "PASS: ci-checks.sh runs and reports all 6 sections"

tmp="$(new_tmp_dir)"
make_ci_fixture "$tmp"
skip_out="$(REQUIRE_SHELLCHECK='' run_ci_fixture "$tmp" 2>&1)"
grep -qF "SKIP: shellcheck not found on PATH" <<< "$skip_out" || {
  echo "FAIL: missing-shellcheck default path did not print a clear SKIP line" >&2
  exit 1
}
echo "PASS: missing shellcheck is skipped by default"

tmp="$(new_tmp_dir)"
make_ci_fixture "$tmp"
set +e
strict_out="$(REQUIRE_SHELLCHECK=1 run_ci_fixture "$tmp" 2>&1)"
strict_status=$?
set -e
if [ "$strict_status" -eq 0 ]; then
  echo "FAIL: REQUIRE_SHELLCHECK=1 should fail when shellcheck is absent" >&2
  exit 1
fi
grep -qF "FAIL: shellcheck is required but was not found on PATH" <<< "$strict_out" || {
  echo "FAIL: strict missing-shellcheck path did not print a clear diagnostic" >&2
  exit 1
}
echo "PASS: REQUIRE_SHELLCHECK=1 fails when shellcheck is absent"

tmp="$(new_tmp_dir)"
make_ci_fixture "$tmp"
cat > "$tmp/bin/shellcheck" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$tmp/shellcheck.log"
echo "fixture shellcheck finding" >&2
exit 7
EOF
chmod +x "$tmp/bin/shellcheck"
set +e
present_out="$(run_ci_fixture "$tmp" 2>&1)"
present_status=$?
set -e
if [ "$present_status" -eq 0 ]; then
  echo "FAIL: shellcheck findings should remain blocking when shellcheck is present" >&2
  echo "$present_out" >&2
  exit 1
fi
grep -qF -- "--severity=warning" "$tmp/shellcheck.log" || {
  echo "FAIL: shellcheck was not invoked with --severity=warning" >&2
  exit 1
}
echo "PASS: shellcheck findings remain blocking when shellcheck is present"
