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

fail() {
  echo "FAIL: $1" >&2
  if [ "${2:-}" ]; then
    echo "$2" >&2
  fi
  exit 1
}

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

make_plugin_root_fixture() {
  local tmp="$1"
  local repo="$tmp/repo"
  local bin="$tmp/bin"
  local tool

  mkdir -p \
    "$bin" \
    "$repo/scripts" \
    "$repo/scripts/_fixtures/roadmap" \
    "$repo/docs/contracts" \
    "$repo/tests/contracts" \
    "$repo/hooks" \
    "$repo/skills" \
    "$repo/.github/ISSUE_TEMPLATE"
  : > "$repo/.github/ISSUE_TEMPLATE/agent-ready.md"

  cp "$CI" "$repo/scripts/ci-checks.sh"
  chmod +x "$repo/scripts/ci-checks.sh"

  for tool in bash cat chmod dirname find git grep head mkdir mktemp rm sed touch xargs; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done

  for tool in \
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

  for tool in bash cat chmod dirname find grep head mkdir mktemp rm sed touch xargs; do
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
  cp "$SCRIPT_DIR/check-release-gate.sh" "$repo/scripts/check-release-gate.sh"
  chmod +x "$repo/scripts/check-version-bump.sh" "$repo/scripts/check-release-gate.sh"

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
for section in "ShellCheck" "Smoke tests" "Declared test command" "Cross-reference" "Contract coverage" "Health check" "Release gate"; do
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
make_plugin_root_fixture "$tmp"
mode_repo="$tmp/repo"

cat > "$mode_repo/scripts/_smoke-test-default.sh" <<'INNER'
#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-parallel: safe
touch default-ran
INNER
cat > "$mode_repo/scripts/_smoke-test-full-only.sh" <<'INNER'
#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-tier: full
# ci-tier-reason: fixture sweep only needed in full mode
# ci-parallel: safe
touch full-ran
INNER
chmod +x "$mode_repo/scripts/_smoke-test-default.sh" "$mode_repo/scripts/_smoke-test-full-only.sh"

(cd "$mode_repo" && PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/mode-balanced.out" 2>&1
[ -f "$mode_repo/default-ran" ] || fail "balanced mode did not run default-tier smoke test"
[ ! -f "$mode_repo/full-ran" ] || fail "balanced mode ran full-only smoke test" "$(cat "$tmp/mode-balanced.out")"
grep -qF "SKIP: scripts/_smoke-test-full-only.sh (ci-tier full; mode balanced)" "$tmp/mode-balanced.out" \
  || fail "balanced mode did not explain full-only skip" "$(cat "$tmp/mode-balanced.out")"
echo "PASS: balanced mode skips explicit full-only smoke tests"

rm -f "$mode_repo/default-ran" "$mode_repo/full-ran"
(cd "$mode_repo" && ARBORETUM_CI_MODE=full PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/mode-full.out" 2>&1
[ -f "$mode_repo/default-ran" ] || fail "full mode did not run default-tier smoke test"
[ -f "$mode_repo/full-ran" ] || fail "full mode did not run full-only smoke test" "$(cat "$tmp/mode-full.out")"
echo "PASS: full mode runs explicit full-only smoke tests"

git -C "$mode_repo" init -q
git -C "$mode_repo" config user.email "fixture@test.com"
git -C "$mode_repo" config user.name "fixture"
git -C "$mode_repo" add .
git -C "$mode_repo" commit -q -m "base"
git -C "$mode_repo" tag base

mkdir -p "$mode_repo/docs/specs"
printf 'docs-only\n' > "$mode_repo/docs/specs/fixture.spec.md"
git -C "$mode_repo" add docs/specs/fixture.spec.md
git -C "$mode_repo" commit -q -m "docs spec change"
rm -f "$mode_repo/default-ran" "$mode_repo/full-ran"
(cd "$mode_repo" && ARBORETUM_CI_MODE=auto BASE_REF=base PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/auto-balanced.out" 2>&1
grep -qF "CI mode: balanced" "$tmp/auto-balanced.out" \
  || fail "auto mode should stay balanced for non-trigger paths" "$(cat "$tmp/auto-balanced.out")"
[ -f "$mode_repo/default-ran" ] || fail "auto balanced did not run default-tier smoke test"
[ ! -f "$mode_repo/full-ran" ] || fail "auto balanced ran full-only smoke test" "$(cat "$tmp/auto-balanced.out")"
echo "PASS: auto mode stays balanced for non-trigger paths"

printf '\n# trigger auto full\n' >> "$mode_repo/scripts/_smoke-test-default.sh"
git -C "$mode_repo" add scripts/_smoke-test-default.sh
git -C "$mode_repo" commit -q -m "smoke test change"
rm -f "$mode_repo/default-ran" "$mode_repo/full-ran"
(cd "$mode_repo" && ARBORETUM_CI_MODE=auto BASE_REF=base PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/auto-full.out" 2>&1
grep -qF "CI mode: full" "$tmp/auto-full.out" \
  || fail "auto mode should escalate to full for smoke-test path changes" "$(cat "$tmp/auto-full.out")"
[ -f "$mode_repo/default-ran" ] || fail "auto full did not run default-tier smoke test"
[ -f "$mode_repo/full-ran" ] || fail "auto full did not run full-only smoke test" "$(cat "$tmp/auto-full.out")"
echo "PASS: auto mode escalates to full for CI/test executable paths"

if (cd "$mode_repo" && ARBORETUM_CI_MODE=turbo PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/bad-mode.out" 2>&1; then
  fail "invalid ARBORETUM_CI_MODE should fail"
fi
grep -qF "FAIL: invalid ARBORETUM_CI_MODE" "$tmp/bad-mode.out" \
  || fail "invalid mode diagnostic missing" "$(cat "$tmp/bad-mode.out")"
echo "PASS: invalid CI mode fails closed"

if (cd "$mode_repo" && ARBORETUM_CI_JOBS=00 PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/bad-jobs.out" 2>&1; then
  fail "all-zero ARBORETUM_CI_JOBS should fail"
fi
grep -qF "FAIL: invalid ARBORETUM_CI_JOBS" "$tmp/bad-jobs.out" \
  || fail "invalid jobs diagnostic missing" "$(cat "$tmp/bad-jobs.out")"
echo "PASS: all-zero CI jobs fails closed"

cat > "$mode_repo/scripts/_smoke-test-bad-parallel.sh" <<'INNER'
#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-parallel: maybe
touch bad-parallel-ran
INNER
chmod +x "$mode_repo/scripts/_smoke-test-bad-parallel.sh"
if (cd "$mode_repo" && PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/bad-parallel.out" 2>&1; then
  fail "invalid ci-parallel should fail"
fi
grep -qF "FAIL: invalid ci-parallel" "$tmp/bad-parallel.out" \
  || fail "invalid ci-parallel diagnostic missing" "$(cat "$tmp/bad-parallel.out")"
rm -f "$mode_repo/scripts/_smoke-test-bad-parallel.sh" "$mode_repo/bad-parallel-ran"
echo "PASS: invalid ci-parallel fails closed"

cat > "$mode_repo/scripts/_smoke-test-full-only.sh" <<'INNER'
#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-tier: weekly
# ci-tier-reason: fixture invalid tier
# ci-parallel: safe
touch full-ran
INNER
chmod +x "$mode_repo/scripts/_smoke-test-full-only.sh"
if (cd "$mode_repo" && PATH="$tmp/bin" bash scripts/ci-checks.sh) >"$tmp/bad-tier.out" 2>&1; then
  fail "invalid ci-tier should fail"
fi
grep -qF "FAIL: invalid ci-tier" "$tmp/bad-tier.out" \
  || fail "invalid tier diagnostic missing" "$(cat "$tmp/bad-tier.out")"
echo "PASS: invalid ci-tier fails closed"

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
