#!/usr/bin/env bash
# owner: git-workflow-tooling
# _smoke-test-ci-checks.sh — assert ci-checks.sh exists, is executable, and
# emits a section header per check against a stubbed fixture. Does not assert
# checks pass in the live repo — only that the entrypoint runs and reports
# structure.
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

make_consumer_ci_fixture() {
  local tmp="$1"
  local repo="$tmp/repo"
  local bin="$tmp/bin"
  local tool

  mkdir -p "$bin" "$repo/scripts" "$repo/.claude/hooks" "$repo/docs/specs"
  cp "$CI" "$repo/scripts/ci-checks.sh"
  chmod +x "$repo/scripts/ci-checks.sh"

  for tool in bash dirname find grep head sed touch; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done

  cat > "$bin/shellcheck" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
  chmod +x "$bin/shellcheck"

  touch "$repo/docs/specs/project-infrastructure.spec.md"

  cat > "$repo/scripts/_smoke-test-project-owned.sh" <<'INNER'
#!/usr/bin/env bash
# owner: project-infrastructure
# scope: consumer
touch "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/project-smoke-ran"
exit 0
INNER
  chmod +x "$repo/scripts/_smoke-test-project-owned.sh"

  cat > "$repo/scripts/_smoke-test-framework-owned.sh" <<'INNER'
#!/usr/bin/env bash
# owner: pipeline-contracts-template
echo "framework smoke test should be skipped in a consumer root" >&2
exit 42
INNER
  chmod +x "$repo/scripts/_smoke-test-framework-owned.sh"

  cat > "$repo/scripts/_smoke-test-reserved-framework-owned.sh" <<'INNER'
#!/usr/bin/env bash
# owner: project-infrastructure
echo "reserved-owner framework smoke test should require an explicit consumer scope" >&2
exit 43
INNER
  chmod +x "$repo/scripts/_smoke-test-reserved-framework-owned.sh"

  cp "$SCRIPT_DIR/check-version-bump.sh" "$repo/scripts/check-version-bump.sh"
  chmod +x "$repo/scripts/check-version-bump.sh"

  for tool in \
    "validate-cross-refs.sh" \
    "validate-coverage-manifest.sh" \
    "health-check.sh"
  do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/$tool"
    chmod +x "$repo/scripts/$tool"
  done
}

make_declared_command_consumer_fixture() {
  local tmp="$1"
  local repo="$tmp/repo"
  local bin="$tmp/bin"
  local python_exe
  local tool

  mkdir -p "$bin" "$repo/scripts/lib" "$repo/docs/specs"
  cp "$CI" "$repo/scripts/ci-checks.sh"
  cp "$SCRIPT_DIR/read-test-config.sh" "$repo/scripts/read-test-config.sh"
  cp "$SCRIPT_DIR/lib/yaml-lite.sh" "$repo/scripts/lib/yaml-lite.sh"
  chmod +x "$repo/scripts/ci-checks.sh" "$repo/scripts/read-test-config.sh" "$repo/scripts/lib/yaml-lite.sh"

  python_exe=$(python3 -c 'import sys; print(sys.executable)')

  for tool in bash dirname find grep head mktemp rm sed touch; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  ln -s "$python_exe" "$bin/python3"

  cat > "$bin/shellcheck" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
  chmod +x "$bin/shellcheck"

  cat > "$repo/scripts/validate-cross-refs.sh" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
  chmod +x "$repo/scripts/validate-cross-refs.sh"

  cat > "$repo/scripts/health-check.sh" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
  chmod +x "$repo/scripts/health-check.sh"

  cat > "$repo/scripts/product-test.sh" <<'INNER'
#!/usr/bin/env bash
touch product-test-ran
exit 0
INNER
  chmod +x "$repo/scripts/product-test.sh"

  cat > "$repo/docs/specs/test-infrastructure.spec.md" <<'INNER'
---
name: test-infrastructure
default-command: bash scripts/product-test.sh
---
INNER
}

run_ci_fixture() {
  local tmp="$1"
  PATH="$tmp/bin" "$(command -v bash)" "$tmp/repo/scripts/ci-checks.sh"
}

tmp="$(new_tmp_dir)"
make_ci_fixture "$tmp"
out="$(REQUIRE_SHELLCHECK='' run_ci_fixture "$tmp" 2>&1)"
for section in "ShellCheck" "Smoke tests" "Declared test command" "Cross-reference" "Contract coverage" "Health check" "Version bump"; do
  grep -qF "$section" <<< "$out" || {
    echo "FAIL: ci-checks.sh output missing section '$section'" >&2; exit 1; }
done
echo "PASS: ci-checks.sh runs and reports all 7 sections"

tmp="$(new_tmp_dir)"
make_ci_fixture "$tmp"
skip_out="$(REQUIRE_SHELLCHECK='' run_ci_fixture "$tmp" 2>&1)"
grep -qF "SKIP: shellcheck not found on PATH" <<< "$skip_out" || {
  echo "FAIL: missing-shellcheck default path did not print a clear SKIP line" >&2
  exit 1
}
echo "PASS: missing shellcheck is skipped by default"

tmp="$(new_tmp_dir)"
make_consumer_ci_fixture "$tmp"
rm -f "$tmp"/repo/scripts/_smoke-test-*.sh
no_smoke_out="$(run_ci_fixture "$tmp" 2>&1)"
if grep -qF "sed:" <<< "$no_smoke_out"; then
  echo "FAIL: consumer roots with no smoke tests should not pass an unmatched glob to sed" >&2
  echo "$no_smoke_out" >&2
  exit 1
fi
echo "PASS: consumer roots with no smoke tests stay quiet"

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

tmp="$(new_tmp_dir)"
make_consumer_ci_fixture "$tmp"
consumer_out="$(run_ci_fixture "$tmp" 2>&1)"
if [ ! -f "$tmp/repo/project-smoke-ran" ]; then
  echo "FAIL: consumer-owned smoke tests should still run in consumer roots" >&2
  echo "$consumer_out" >&2
  exit 1
fi
grep -qF "SKIP: scripts/_smoke-test-framework-owned.sh" <<< "$consumer_out" || {
  echo "FAIL: framework-owned smoke test did not print a SKIP line in consumer root" >&2
  echo "$consumer_out" >&2
  exit 1
}
grep -qF "SKIP: scripts/_smoke-test-reserved-framework-owned.sh (no consumer-applicable scope declared)" <<< "$consumer_out" || {
  echo "FAIL: reserved-owner framework smoke test without consumer scope was not skipped" >&2
  echo "$consumer_out" >&2
  exit 1
}
grep -qF "SKIP: plugin version manifests not found" <<< "$consumer_out" || {
  echo "FAIL: real version-bump gate did not skip cleanly in consumer root" >&2
  echo "$consumer_out" >&2
  exit 1
}
echo "PASS: consumer roots skip inapplicable framework smoke tests without requiring plugin dirs"

tmp="$(new_tmp_dir)"
make_declared_command_consumer_fixture "$tmp"
set +e
declared_out="$(run_ci_fixture "$tmp" 2>&1)"
declared_status=$?
set -e
if [ "$declared_status" -ne 0 ]; then
  echo "FAIL: consumer root ci-checks should exit cleanly when declared tests pass and plugin-only checks are absent" >&2
  echo "$declared_out" >&2
  exit 1
fi
if [ ! -f "$tmp/repo/product-test-ran" ]; then
  echo "FAIL: consumer roots should run the declared default-command" >&2
  echo "$declared_out" >&2
  exit 1
fi
if grep -qF "No such file or directory" <<< "$declared_out"; then
  echo "FAIL: consumer roots should skip absent plugin-only checks instead of hard-calling them" >&2
  echo "$declared_out" >&2
  exit 1
fi
grep -qF "SKIP: scripts/validate-coverage-manifest.sh not installed in this root" <<< "$declared_out" || {
  echo "FAIL: missing contract-coverage gate did not print a consumer skip line" >&2
  echo "$declared_out" >&2
  exit 1
}
grep -qF "SKIP: scripts/check-version-bump.sh not installed in this root" <<< "$declared_out" || {
  echo "FAIL: missing version-bump gate did not print a consumer skip line" >&2
  echo "$declared_out" >&2
  exit 1
}
echo "PASS: consumer roots run declared default-command and skip absent plugin-only checks"
