#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-checks.sh — canonical check entrypoint. Run by the pre-PR local gate
# (skills/finish) and, once #206 merges, by .github/workflows/ci.yml — so the
# local gate and CI cannot drift. Exit 0 only if all blocking checks pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
CI_MODE="${ARBORETUM_CI_MODE:-balanced}"
CI_JOBS="${ARBORETUM_CI_JOBS:-8}"
smoke_selection_failed=0

case "$CI_MODE" in
  balanced|full|auto) ;;
  *)
    echo "FAIL: invalid ARBORETUM_CI_MODE '$CI_MODE' (expected balanced, full, or auto)" >&2
    exit 1
    ;;
esac

case "$CI_JOBS" in
  ''|*[!0-9]*)
    echo "FAIL: invalid ARBORETUM_CI_JOBS '$CI_JOBS' (expected positive integer)" >&2
    exit 1
    ;;
esac
case "$CI_JOBS" in
  *[1-9]*) ;;
  *)
    echo "FAIL: invalid ARBORETUM_CI_JOBS '$CI_JOBS' (expected positive integer)" >&2
    exit 1
    ;;
esac

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

run_declared_default_command() {
  local spec="docs/specs/test-infrastructure.spec.md"
  local reader="scripts/read-test-config.sh"
  local config default_command

  if [ "${ARBORETUM_CI_CHECKS_RUNNING_DEFAULT:-0}" = "1" ]; then
    echo "SKIP: declared default-command already running"
    return
  fi

  if is_plugin_root; then
    echo "SKIP: plugin root runs framework checks directly"
    return
  fi

  if [ ! -f "$spec" ]; then
    echo "SKIP: $spec not found"
    return
  fi

  if [ ! -f "$reader" ]; then
    echo "FAIL: $reader not installed; cannot read declared default-command" >&2
    fail=1
    return
  fi

  if ! config="$(bash "$reader" "$spec")"; then
    fail=1
    return
  fi

  default_command="$(printf '%s\n' "$config" | sed -n 's/^default-command=//p' | head -1)"
  if [ -z "$default_command" ]; then
    echo "FAIL: $reader did not emit default-command" >&2
    fail=1
    return
  fi

  echo "--- $default_command ---"
  ARBORETUM_CI_CHECKS_RUNNING_DEFAULT=1 bash -c "$default_command" || fail=1
}

run_plugin_check_if_available() {
  local script="$1"

  if [ -f "$script" ]; then
    bash "$script" || fail=1
    return
  fi

  if is_plugin_root; then
    echo "FAIL: $script missing in plugin root" >&2
    fail=1
  else
    echo "SKIP: $script not installed in this root"
  fi
}

ci_mode_triggered_by_path() {
  local path="$1"

  case "$path" in
    scripts/ci-checks.sh|scripts/_smoke-test-*.sh|tests/contracts/*|.github/workflows/*)
      return 0
      ;;
    .claude-plugin/plugin.json|.claude-plugin/marketplace.json|.codex-plugin/plugin.json|docs/releases/*|CHANGELOG.md)
      return 0
      ;;
  esac

  return 1
}

resolve_ci_mode() {
  local mode="$1"
  local base_ref merge_base changed path

  if [ "$mode" != "auto" ]; then
    printf '%s\n' "$mode"
    return 0
  fi

  base_ref="${BASE_REF:-origin/main}"
  if ! merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null)"; then
    echo "WARN: could not resolve BASE_REF '$base_ref'; using full CI mode" >&2
    printf '%s\n' "full"
    return 0
  fi

  if ! changed="$(git diff --name-only "$merge_base" HEAD 2>/dev/null)"; then
    echo "WARN: could not read changed paths; using full CI mode" >&2
    printf '%s\n' "full"
    return 0
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ci_mode_triggered_by_path "$path"; then
      printf '%s\n' "full"
      return 0
    fi
  done <<< "$changed"

  printf '%s\n' "balanced"
}

smoke_test_tier() {
  local f="$1"
  local line tier

  line="$(sed -n '1,12{/^# ci-tier: /p;}' "$f" | head -1)"
  if [ -z "$line" ]; then
    printf '%s\n' "balanced"
    return 0
  fi

  tier="${line#"# ci-tier: "}"
  case "$tier" in
    balanced|full)
      printf '%s\n' "$tier"
      ;;
    *)
      echo "FAIL: invalid ci-tier '$tier' in $f" >&2
      return 2
      ;;
  esac
}

smoke_test_parallel_mode() {
  local f="$1"
  local line mode

  line="$(sed -n '1,12{/^# ci-parallel: /p;}' "$f" | head -1)"
  if [ -z "$line" ]; then
    printf '%s\n' "serial"
    return 0
  fi

  mode="${line#"# ci-parallel: "}"
  case "$mode" in
    safe|serial)
      printf '%s\n' "$mode"
      ;;
    *)
      echo "FAIL: invalid ci-parallel '$mode' in $f" >&2
      return 2
      ;;
  esac
}

smoke_test_selected_for_mode() {
  local f="$1"
  local tier

  if ! tier="$(smoke_test_tier "$f")"; then
    fail=1
    smoke_selection_failed=1
    return 1
  fi

  if [ "$tier" = "full" ] && [ "$EFFECTIVE_CI_MODE" != "full" ]; then
    echo "SKIP: $f (ci-tier full; mode $EFFECTIVE_CI_MODE)"
    return 1
  fi

  return 0
}

run_smoke_test_serial() {
  local f="$1"

  echo "--- $f ---"
  bash "$f" || fail=1
}

run_smoke_tests_parallel() {
  local tmp list statuses worker idx f rc

  tmp="$(mktemp -d)"
  list="$tmp/list"
  statuses="$tmp/statuses"
  mkdir -p "$tmp/logs" "$statuses"

  worker="$tmp/run-one.sh"
  cat > "$worker" <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
log_dir="$1"
status_dir="$2"
idx="$3"
script="$4"
if bash "$script" >"$log_dir/$idx.out" 2>&1; then
  printf "0\n" >"$status_dir/$idx"
else
  printf "%s\n" "$?" >"$status_dir/$idx"
fi
INNER
  chmod +x "$worker"

  idx=0
  for f in "$@"; do
    idx=$((idx + 1))
    printf '%s %s\n' "$idx" "$f" >> "$list"
  done

  if [ ! -s "$list" ]; then
    rm -rf "$tmp"
    return 0
  fi

  xargs -P "$CI_JOBS" -n 2 "$worker" "$tmp/logs" "$statuses" < "$list"

  while read -r idx f; do
    echo "--- $f ---"
    [ -f "$tmp/logs/$idx.out" ] && cat "$tmp/logs/$idx.out"
    rc="$(cat "$statuses/$idx" 2>/dev/null || printf '1')"
    if [ "$rc" != "0" ]; then
      echo "FAIL: $f exited $rc" >&2
      fail=1
    fi
  done < "$list"

  rm -rf "$tmp"
}

run_smoke_tests_selected() {
  local f mode
  local parallel_batch=()

  for f in "$@"; do
    if [ "$CI_JOBS" = "1" ]; then
      run_smoke_test_serial "$f"
      continue
    fi

    mode="$(smoke_test_parallel_mode "$f")" || {
      fail=1
      continue
    }

    if [ "$mode" = "safe" ]; then
      parallel_batch+=("$f")
      continue
    fi

    if [ "${#parallel_batch[@]}" -gt 0 ]; then
      run_smoke_tests_parallel "${parallel_batch[@]}"
      parallel_batch=()
    fi

    run_smoke_test_serial "$f"
  done

  if [ "$CI_JOBS" != "1" ] && [ "${#parallel_batch[@]}" -gt 0 ]; then
    run_smoke_tests_parallel "${parallel_batch[@]}"
  fi
}

EFFECTIVE_CI_MODE="$(resolve_ci_mode "$CI_MODE")"
echo "CI mode: $EFFECTIVE_CI_MODE"

echo "=== ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_roots=()
  for root in scripts .claude/hooks skills dev-tools; do
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
selected_smoke_tests=()
for f in scripts/_smoke-test-*.sh; do
  [ -e "$f" ] || continue
  [[ "$f" == *"_smoke-test-ci-checks.sh" ]] && continue  # skip self-referential meta-test
  smoke_test_applicable "$f" || continue
  smoke_test_selected_for_mode "$f" || continue
  smoke_test_parallel_mode "$f" >/dev/null || {
    fail=1
    smoke_selection_failed=1
    continue
  }
  selected_smoke_tests+=("$f")
done

if [ "$smoke_selection_failed" = "0" ]; then
  run_smoke_tests_selected "${selected_smoke_tests[@]}"
fi

echo "=== Declared test command ==="
run_declared_default_command

echo "=== Cross-reference validation ==="
bash scripts/validate-cross-refs.sh || fail=1

echo "=== Contract coverage validation ==="
run_plugin_check_if_available "scripts/validate-coverage-manifest.sh"

echo "=== Health check (non-blocking) ==="
bash scripts/health-check.sh "$ROOT" || echo "(health-check reported issues — non-blocking)"

echo "=== Release gate ==="
run_plugin_check_if_available "dev-tools/release/check-version-bump.sh"

exit $fail
