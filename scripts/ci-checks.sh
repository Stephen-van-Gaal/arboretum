#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-checks.sh — canonical check entrypoint. Run by the pre-PR local gate
# (skills/finish) and, once #206 merges, by .github/workflows/ci.yml — so the
# local gate and CI cannot drift. Exit 0 only if all blocking checks pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
source "$ROOT/scripts/lib/owner-doc-resolve.sh"   # group-aware # owner: resolution (D7, #681)
fail=0
# Failing-stage rollup (#839): record the stage where `fail` first flips so a
# failed run can name the failing stage in $GITHUB_STEP_SUMMARY at a glance.
# `fail` is monotonic 0->1, so this attributes the FIRST failing stage (the
# actionable root cause); rollup_mark is a no-op once a stage has been recorded.
ROLLUP_FAILED=()
_rollup_prev_fail=0
rollup_mark() {
  if [ "$fail" != "$_rollup_prev_fail" ]; then
    ROLLUP_FAILED+=("$1")
    _rollup_prev_fail="$fail"
  fi
}
CI_MODE="${ARBORETUM_CI_MODE:-balanced}"
CI_JOBS="${ARBORETUM_CI_JOBS:-8}"
CI_READONLY="${ARBORETUM_CI_READONLY:-0}"   # 1 = zero-mutation verification run (#688)
smoke_selection_failed=0
TOKEN_RUNTIME_BYTES=0   # token accounting: replayed smoke-test output bytes

case "$CI_MODE" in
  balanced|full|auto) ;;
  *)
    echo "FAIL: invalid ARBORETUM_CI_MODE '$CI_MODE' (expected balanced, full, or auto)" >&2
    exit 1
    ;;
esac

case "$CI_READONLY" in
  0|1) ;;
  *)
    echo "FAIL: invalid ARBORETUM_CI_READONLY '$CI_READONLY' (expected 0 or 1)" >&2
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

# Quiet mode (#601): default-quiet so agent-invoked local runs (/finish, /build)
# do not dump green-test transcripts into model context. Disabled — output
# reverts to the verbose, byte-for-byte legacy behaviour — when running under a
# CI runner ($CI set, e.g. GitHub Actions) or when explicitly overridden with
# ARBORETUM_CI_VERBOSE=1.
QUIET=1
if [ -n "${CI:-}" ] || [ "${ARBORETUM_CI_VERBOSE:-0}" = "1" ]; then
  QUIET=0
fi
RAW_LOG=".arboretum/ci-checks-last.log"
if [ "$QUIET" = "1" ]; then
  mkdir -p .arboretum
  : > "$RAW_LOG"
fi
# Smoke-test tallies for the quiet-mode per-stage summary.
smoke_pass=0
smoke_fail=0
smoke_skip=0

# run_capture <cmd...> — in quiet mode route the command's combined output to the
# raw log and replay it to stdout only on a non-zero exit (failing-item-first
# diagnostics), printing a compact "  ok" on success; in verbose mode run the
# command unchanged so legacy output is preserved. Returns the command's status.
run_capture() {
  if [ "$QUIET" != "1" ]; then
    "$@"
    return $?
  fi
  local slice rc
  slice="$(mktemp)"
  "$@" >"$slice" 2>&1
  rc=$?
  cat "$slice" >> "$RAW_LOG"
  if [ "$rc" = "0" ]; then
    echo "  ok"
  else
    cat "$slice"
  fi
  rm -f "$slice"
  return $rc
}

is_plugin_root() {
  [ -d skills ] \
    && [ -d hooks ] \
    && [ -d docs/contracts ] \
    && [ -d tests/contracts ] \
    && [ -d scripts/_fixtures/roadmap ] \
    && [ -f .github/ISSUE_TEMPLATE/agent-ready.md ]
}

is_plugin_manifest_root() {
  [ -f .claude-plugin/plugin.json ] \
    || [ -f .codex-plugin/plugin.json ]
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
    if ! owner_doc_path "$owner_name" "$ROOT" >/dev/null; then
      echo "SKIP: $f (owner '$owner_name' has no spec or group installed in this root)"
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
  ARBORETUM_CI_CHECKS_RUNNING_DEFAULT=1 run_capture bash -c "$default_command" || fail=1
}

run_plugin_check_if_available() {
  local script="$1"

  if [ -f "$script" ]; then
    run_capture bash "$script" || fail=1
    return
  fi

  if is_plugin_root; then
    echo "FAIL: $script missing in plugin root" >&2
    fail=1
  else
    echo "SKIP: $script not installed in this root"
  fi
}

run_contract_coverage_check_if_available() {
  local script="scripts/validate-coverage-manifest.sh"

  if [ ! -d docs/contracts ] && is_plugin_manifest_root; then
    echo "FAIL: docs/contracts missing in plugin root; cannot run $script" >&2
    fail=1
    return
  fi

  if [ ! -f "$script" ]; then
    run_plugin_check_if_available "$script"
    return
  fi

  if [ ! -d docs/contracts ]; then
    echo "SKIP: $script requires docs/contracts in this root"
    return
  fi

  run_capture bash "$script" || fail=1
}

run_ci_preflight() {
  if [ "${ARBORETUM_CI_PREFLIGHT_DONE:-0}" = "1" ]; then
    echo "SKIP: CI preflight already completed by caller"
    return 0
  fi

  # Read-only verification mode (#688): drop --apply-safe-repairs so the only
  # mutating stage in the orchestrator stays read-only. Every other stage is
  # already read-only, so ARBORETUM_CI_READONLY=1 makes the whole run zero-
  # mutation. A genuine coverage drift still BLOCKS (preflight without the flag
  # exits 1 on COVERAGE-MANIFEST-DRIFT) — report, don't repair.
  if [ "$CI_READONLY" = "1" ]; then
    if run_capture bash scripts/ci-preflight.sh; then
      return 0
    fi
  elif run_capture bash scripts/ci-preflight.sh --apply-safe-repairs; then
    return 0
  fi
  # Preflight is a hard stop gate (caller does `run_ci_preflight || exit 1`), so
  # print the raw-log pointer the contract promises on every failing quiet run
  # before that exit fires.
  [ "$QUIET" = "1" ] && echo "Checks FAILED · full log: $RAW_LOG"
  return 1
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
  local slice rc _b
  slice="$(mktemp)"
  bash "$f" >"$slice" 2>&1
  rc=$?
  # token accounting: byte-count the test body (parity with the parallel path,
  # which counts $idx.out, not the header). Most smoke tests default to the
  # serial path, so without this the runtime ledger systematically undercounts.
  _b="$(wc -c < "$slice" | tr -d ' ')"

  if [ "$QUIET" != "1" ]; then
    # verbose: replay output to stdout; the caller absorbs all of it.
    echo "--- $f ---"
    cat "$slice"
    TOKEN_RUNTIME_BYTES=$(( TOKEN_RUNTIME_BYTES + ${_b:-0} ))
    [ "$rc" = "0" ] || fail=1
    rm -f "$slice"
    return
  fi

  { echo "--- $f ---"; cat "$slice"; } >> "$RAW_LOG"
  if [ "$rc" = "0" ]; then
    smoke_pass=$((smoke_pass + 1))
  else
    smoke_fail=$((smoke_fail + 1))
    echo "--- $f ---"
    cat "$slice"
    # quiet mode: only this replayed failing output reaches stdout, so count it.
    TOKEN_RUNTIME_BYTES=$(( TOKEN_RUNTIME_BYTES + ${_b:-0} ))
    echo "FAIL: $f exited $rc" >&2
    fail=1
  fi
  rm -f "$slice"
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
    rc="$(cat "$statuses/$idx" 2>/dev/null || printf '1')"
    if [ "$QUIET" = "1" ]; then
      { echo "--- $f ---"; [ -f "$tmp/logs/$idx.out" ] && cat "$tmp/logs/$idx.out"; } >> "$RAW_LOG"
      if [ "$rc" = "0" ]; then
        smoke_pass=$((smoke_pass + 1))
      else
        smoke_fail=$((smoke_fail + 1))
        echo "--- $f ---"
        if [ -f "$tmp/logs/$idx.out" ]; then
          cat "$tmp/logs/$idx.out"
          # token accounting: under quiet mode only failing output reaches stdout
          _b="$(wc -c < "$tmp/logs/$idx.out" | tr -d ' ')"
          TOKEN_RUNTIME_BYTES=$(( TOKEN_RUNTIME_BYTES + ${_b:-0} ))
        fi
        echo "FAIL: $f exited $rc" >&2
        fail=1
      fi
      continue
    fi
    echo "--- $f ---"
    if [ -f "$tmp/logs/$idx.out" ]; then
      cat "$tmp/logs/$idx.out"
      # token accounting: sum the replayed output bytes a caller would absorb
      _b="$(wc -c < "$tmp/logs/$idx.out" | tr -d ' ')"
      TOKEN_RUNTIME_BYTES=$(( TOKEN_RUNTIME_BYTES + ${_b:-0} ))
    fi
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
if [ "$QUIET" = "1" ]; then
  echo "(quiet mode — passing output goes to $RAW_LOG; set ARBORETUM_CI_VERBOSE=1 for the full stream)"
fi

echo "=== CI preflight ==="
run_ci_preflight || exit 1

echo "=== ShellCheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_roots=()
  for root in scripts .claude/hooks skills dev-tools; do
    [ -d "$root" ] && shellcheck_roots+=("$root")
  done

  if [ "${#shellcheck_roots[@]}" -eq 0 ]; then
    echo "SKIP: no ShellCheck roots found"
  else
    run_capture find "${shellcheck_roots[@]}" -name '*.sh' ! -path '*/_archived/*' \
      -exec shellcheck --severity=warning {} + || fail=1
  fi
elif [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
  echo "FAIL: shellcheck is required but was not found on PATH" >&2
  fail=1
else
  echo "SKIP: shellcheck not found on PATH (set REQUIRE_SHELLCHECK=1 to require it)"
fi

rollup_mark "ShellCheck"

echo "=== Smoke tests ==="
selected_smoke_tests=()
for f in scripts/_smoke-test-*.sh; do
  [ -e "$f" ] || continue
  [[ "$f" == *"_smoke-test-ci-checks.sh" ]] && continue  # skip self-referential meta-test
  smoke_test_applicable "$f" || { smoke_skip=$((smoke_skip + 1)); continue; }
  # smoke_test_selected_for_mode returns non-zero for a legitimate full-tier
  # skip AND for malformed metadata (where it also sets smoke_selection_failed).
  # Only the former is a real skip — counting a metadata error as "skipped"
  # would hide the selection failure behind a green-looking summary.
  smoke_test_selected_for_mode "$f" || {
    [ "$smoke_selection_failed" = "1" ] || smoke_skip=$((smoke_skip + 1))
    continue
  }
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
if [ "$QUIET" = "1" ]; then
  echo "  ${smoke_pass} passed · ${smoke_skip} skipped · ${smoke_fail} failed"
fi

rollup_mark "Smoke tests"

echo "=== Declared test command ==="
run_declared_default_command
rollup_mark "Declared test command"

echo "=== Cross-reference validation ==="
run_capture bash scripts/validate-cross-refs.sh || fail=1
rollup_mark "Cross-reference validation"

echo "=== Contract coverage validation ==="
run_contract_coverage_check_if_available
rollup_mark "Contract coverage validation"

echo "=== Release gate ==="
run_plugin_check_if_available "dev-tools/release/check-version-bump.sh"
rollup_mark "Release gate"

if [ "$QUIET" = "1" ]; then
  if [ "$fail" = "0" ]; then
    echo "All checks passed · full log: $RAW_LOG"
  else
    echo "Checks FAILED · full log: $RAW_LOG"
  fi
fi

# --- token accounting (advisory; never affects output/exit) ---
# Measures the smoke-test output bytes a caller absorbs on stdout. Under quiet
# mode (#610, now default) only failing-test output is replayed to stdout, so
# this count reflects the reduced surface; verbose/CI runs count the full stream.
if [ -f scripts/lib/token-ledger.sh ]; then
  source scripts/lib/token-ledger.sh
  ARBORETUM_BUCKET=on-demand ledger_append runtime "ci-checks" "${TOKEN_RUNTIME_BYTES:-0}" 2>/dev/null || true
fi

# Failing-stage rollup (#839): on failure, name the failing stage(s) in the
# GitHub step summary so a red run is legible at a glance. Side output only —
# never touches stdout or the exit code (CLI-3: script still ends with exit $fail).
if [ "$fail" != "0" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ❌ ci-checks failed"
    echo ""
    if [ "${#ROLLUP_FAILED[@]}" -gt 0 ]; then
      echo "First failing stage: **${ROLLUP_FAILED[0]}**"
      echo ""
      echo "<sub>Subsequent stages may also have failed; see the full log. Stage attribution is monotonic (first flip).</sub>"
    else
      echo "Failing stage could not be attributed (failure occurred outside a tracked stage); see the full log."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit $fail
