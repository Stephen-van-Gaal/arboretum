#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/contracts/ci-checks.cli-contract.md.
# Asserts structural invariants of scripts/ci-checks.sh by inspecting the
# script source — it does NOT execute ci-checks.sh.
#
# !! CRITICAL: DO NOT invoke `bash scripts/ci-checks.sh` here !!
# ci-checks.sh's smoke-test loop runs every scripts/_smoke-test-*.sh file
# (the only skip is the literal name `_smoke-test-ci-checks.sh`, which is
# NOT this file's name). Executing ci-checks.sh from this smoke test would
# therefore create infinite recursion in CI. All assertions below are purely
# structural: they grep the script source to verify shape invariants without
# running the orchestrator.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/ci-checks.sh"
CONTRACT="$SCRIPT_DIR/../docs/contracts/ci-checks.cli-contract.md"

[ -f "$TARGET" ] || { echo "FAIL: ci-checks.sh not found at $TARGET" >&2; exit 1; }
[ -f "$CONTRACT" ] || { echo "FAIL: ci-checks contract not found at $CONTRACT" >&2; exit 1; }

fail=0

# ---------------------------------------------------------------------------
# CLI-1: Stage-banner sequence
# Preflight plus the six expensive-stage banners must be present and appear in
# the documented order.
# ---------------------------------------------------------------------------
BANNERS=(
  "=== CI preflight ==="
  "=== ShellCheck ==="
  "=== Smoke tests ==="
  "=== Declared test command ==="
  "=== Cross-reference validation ==="
  "=== Contract coverage validation ==="
  "=== Release gate ==="
)

prev_line=0
for banner in "${BANNERS[@]}"; do
  line_no=$(grep -n "$banner" "$TARGET" | head -1 | cut -d: -f1)
  if [ -z "$line_no" ]; then
    echo "FAIL: CLI-1 — banner not found in $TARGET: '$banner'" >&2
    fail=1
  elif [ "$line_no" -le "$prev_line" ]; then
    echo "FAIL: CLI-1 — banner '$banner' (line $line_no) appears before or at previous banner (line $prev_line)" >&2
    fail=1
  else
    prev_line="$line_no"
  fi
done
[ "$fail" -eq 0 ] && echo "PASS: CLI-1 — preflight plus expensive-stage banners present and in order"

# ---------------------------------------------------------------------------
# CLI-2: preflight stop gate and fail-flag accumulation
# The script must initialise fail=0 and accumulate expensive-stage blocking
# failures. Preflight is different: it exits immediately before expensive work.
# ---------------------------------------------------------------------------
if ! grep -q '^fail=0' "$TARGET"; then
  echo "FAIL: CLI-2 — 'fail=0' initialisation not found" >&2
  fail=1
else
  echo "PASS: CLI-2a — fail=0 initialisation present"
fi

# Count lines containing `|| fail=1` (threshold is intentionally loose because
# some blocking stages set fail=1 through helpers rather than inline guards).
fail1_count=$(grep -c '|| fail=1' "$TARGET" || true)
if [ "$fail1_count" -lt 4 ]; then
  echo "FAIL: CLI-2 — expected ≥4 '|| fail=1' accumulations, found $fail1_count" >&2
  fail=1
else
  echo "PASS: CLI-2b — found $fail1_count '|| fail=1' accumulations (≥4)"
fi

if grep -q '^run_ci_preflight()' "$TARGET" \
  && grep -q 'ARBORETUM_CI_PREFLIGHT_DONE' "$TARGET" \
  && grep -q 'bash scripts/ci-preflight.sh --apply-safe-repairs' "$TARGET" \
  && grep -q 'run_ci_preflight || exit 1' "$TARGET"; then
  echo "PASS: CLI-2c — preflight is a first stop gate with hosted skip guard"
else
  echo "FAIL: CLI-2c — preflight stop gate shape is missing" >&2
  fail=1
fi

if grep -q 'Health check (non-blocking)' "$TARGET"; then
  echo "FAIL: CLI-2d — late non-blocking health-check tail is still present" >&2
  fail=1
else
  echo "PASS: CLI-2d — late non-blocking health-check tail is absent"
fi

# ---------------------------------------------------------------------------
# CLI-3: Exit discipline — script ends with `exit $fail`
# ---------------------------------------------------------------------------
if grep -q '^exit \$fail' "$TARGET"; then
  echo "PASS: CLI-3 — script ends with 'exit \$fail'"
else
  echo "FAIL: CLI-3 — 'exit \$fail' not found as a standalone line" >&2
  fail=1
fi

if grep -q 'Preflight failures stop before the expensive-stage accumulator' "$CONTRACT"; then
  echo "PASS: CLI-3 — contract documents preflight early exit boundary"
else
  echo "FAIL: CLI-3 — contract still overstates final fail-flag exit discipline" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-4: Smoke-test self-exclusion — the loop skips `_smoke-test-ci-checks.sh`
# The skip guard must reference the literal name that matches THIS file.
# ---------------------------------------------------------------------------
if grep -q '_smoke-test-ci-checks\.sh' "$TARGET"; then
  echo "PASS: CLI-4 — self-exclusion guard for _smoke-test-ci-checks.sh is present"
else
  echo "FAIL: CLI-4 — smoke-test loop has no self-exclusion guard for _smoke-test-ci-checks.sh" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-5: Root resolution — ROOT derived from BASH_SOURCE[0], not from $PWD
# ---------------------------------------------------------------------------
if grep -q 'BASH_SOURCE\[0\]' "$TARGET"; then
  echo "PASS: CLI-5 — ROOT derived from BASH_SOURCE[0] (location-independent)"
else
  echo "FAIL: CLI-5 — ROOT not derived from BASH_SOURCE[0]; location-dependent invocation" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-6: ShellCheck capability gate
# ShellCheck runs when present, skips by default when absent, and fails closed
# when REQUIRE_SHELLCHECK=1.
# ---------------------------------------------------------------------------
if grep -q 'command -v shellcheck' "$TARGET"; then
  echo "PASS: CLI-6a — shellcheck availability is checked before invocation"
else
  echo "FAIL: CLI-6a — shellcheck is not capability-gated with command -v" >&2
  fail=1
fi

if grep -q 'REQUIRE_SHELLCHECK' "$TARGET"; then
  echo "PASS: CLI-6b — REQUIRE_SHELLCHECK strict mode is present"
else
  echo "FAIL: CLI-6b — REQUIRE_SHELLCHECK strict mode is not present" >&2
  fail=1
fi

if grep -q 'SKIP: shellcheck not found on PATH' "$TARGET"; then
  echo "PASS: CLI-6c — missing shellcheck default path emits a SKIP diagnostic"
else
  echo "FAIL: CLI-6c — missing shellcheck default path has no SKIP diagnostic" >&2
  fail=1
fi

if grep -q 'for root in scripts .claude/hooks skills dev-tools' "$TARGET"; then
  echo "PASS: CLI-6d — ShellCheck includes dev-tools"
else
  echo "FAIL: CLI-6d — ShellCheck roots do not include dev-tools" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-7: Consumer-root applicability
# Consumer roots may not have the plugin development tree. ShellCheck must
# build its root list from existing directories, and smoke tests whose owning
# spec is not installed in the host root must be skipped with a diagnostic.
# ---------------------------------------------------------------------------
if grep -q 'shellcheck_roots=()' "$TARGET" \
  && grep -q '\[ -d "$root" \] && shellcheck_roots' "$TARGET"; then
  echo "PASS: CLI-7a — ShellCheck roots are filtered to existing directories"
else
  echo "FAIL: CLI-7a — ShellCheck roots are not filtered to existing directories" >&2
  fail=1
fi

if grep -q '^is_plugin_root()' "$TARGET" \
  && grep -q '^smoke_test_applicable()' "$TARGET"; then
  echo "PASS: CLI-7b — plugin-root detection and smoke-test applicability helpers are present"
else
  echo "FAIL: CLI-7b — plugin-root/applicability helpers are missing" >&2
  fail=1
fi

if grep -q "owner '.*' spec is not installed in this root" "$TARGET"; then
  echo "PASS: CLI-7c — inapplicable framework smoke tests emit a SKIP diagnostic"
else
  echo "FAIL: CLI-7c — inapplicable smoke-test skip diagnostic is missing" >&2
  fail=1
fi

if grep -q 'scope_re=' "$TARGET" \
  && grep -q 'no consumer-applicable scope declared' "$TARGET"; then
  echo "PASS: CLI-7d — consumer roots require explicit consumer/any smoke-test scope"
else
  echo "FAIL: CLI-7d — consumer-root scope declaration gate is missing" >&2
  fail=1
fi

if grep -q '^run_plugin_check_if_available()' "$TARGET" \
  && grep -q 'not installed in this root' "$TARGET" \
  && grep -q 'missing in plugin root' "$TARGET"; then
  echo "PASS: CLI-7e — plugin-only script checks are file-guarded for consumer roots"
else
  echo "FAIL: CLI-7e — plugin-only script checks are not guarded by root/file availability" >&2
  fail=1
fi

if grep -q '^run_contract_coverage_check_if_available()' "$TARGET" \
  && grep -q 'requires docs/contracts in this root' "$TARGET" \
  && grep -q 'docs/contracts missing in plugin root' "$TARGET"; then
  echo "PASS: CLI-7f — installed contract-coverage validator is input-guarded in consumer roots"
else
  echo "FAIL: CLI-7f — contract-coverage validator is not guarded by docs/contracts availability" >&2
  fail=1
fi

if grep -q 'run_plugin_check_if_available "dev-tools/release/check-version-bump.sh"' "$TARGET"; then
  echo "PASS: CLI-7g — release gate uses dev-only tooling path"
else
  echo "FAIL: CLI-7g — release gate does not use dev-tools/release/check-version-bump.sh" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-8: Empty smoke-test glob
# Consumer roots may have no scripts/_smoke-test-*.sh files. The loop must not
# hand an unmatched literal glob to smoke_test_applicable/sed.
# ---------------------------------------------------------------------------
if grep -qF '[ -e "$f" ] || continue' "$TARGET"; then
  echo "PASS: CLI-8 — smoke-test loop ignores unmatched globs"
else
  echo "FAIL: CLI-8 — smoke-test loop can pass an unmatched glob to sed" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-9: Consumer declared test command
# Consumer roots with a testing-shape declaration must run default-command
# through read-test-config.sh.
# ---------------------------------------------------------------------------
if grep -q '^run_declared_default_command()' "$TARGET" \
  && grep -q 'read-test-config.sh' "$TARGET" \
  && grep -q 'default-command=' "$TARGET" \
  && grep -q 'bash -c "$default_command"' "$TARGET"; then
  echo "PASS: CLI-9 — declared default-command reader path is present"
else
  echo "FAIL: CLI-9 — declared default-command reader path is missing" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# CLI-10: CI modes, smoke-test tiers, and parallel-safety metadata
# The orchestrator owns mode selection, full-only metadata, opt-in bounded
# parallelism, and metadata-driven selection. It must not hard-code individual
# full-only smoke-test paths into the runner.
# ---------------------------------------------------------------------------
if grep -q 'ARBORETUM_CI_MODE' "$TARGET"; then
  echo "PASS: CLI-10a — ARBORETUM_CI_MODE support is present"
else
  echo "FAIL: CLI-10a — ARBORETUM_CI_MODE support is missing" >&2
  fail=1
fi

if grep -q 'ARBORETUM_CI_JOBS' "$TARGET"; then
  echo "PASS: CLI-10b — ARBORETUM_CI_JOBS support is present"
else
  echo "FAIL: CLI-10b — ARBORETUM_CI_JOBS support is missing" >&2
  fail=1
fi

if grep -q 'ci-tier' "$TARGET"; then
  echo "PASS: CLI-10c — ci-tier selector is present"
else
  echo "FAIL: CLI-10c — ci-tier selector is missing" >&2
  fail=1
fi

if grep -q 'ci-parallel' "$TARGET"; then
  echo "PASS: CLI-10e — ci-parallel selector is present"
else
  echo "FAIL: CLI-10e — ci-parallel selector is missing" >&2
  fail=1
fi

if grep -q 'scripts/_smoke-test-runtime-portability.sh' "$TARGET"; then
  echo "FAIL: CLI-10d — full-only selection should be metadata-driven, not hard-coded to runtime portability" >&2
  fail=1
else
  echo "PASS: CLI-10d — no hard-coded runtime-portability denylist in ci-checks.sh"
fi

# ---------------------------------------------------------------------------
# CLI-14: Quiet mode (#601)
# Default-quiet-except-CI output mode: gated on $CI / ARBORETUM_CI_VERBOSE,
# writes a stable raw log, and is documented in the contract at version 1.12.
# (CLI-13 is the preflight gate added by #600.)
# ---------------------------------------------------------------------------
if grep -q 'ARBORETUM_CI_VERBOSE' "$TARGET" \
  && grep -q '\${CI:-}' "$TARGET"; then
  echo "PASS: CLI-14a — quiet mode is gated on \$CI and ARBORETUM_CI_VERBOSE"
else
  echo "FAIL: CLI-14a — quiet-mode trigger (\$CI / ARBORETUM_CI_VERBOSE) is missing" >&2
  fail=1
fi

if grep -q '\.arboretum/ci-checks-last\.log' "$TARGET"; then
  echo "PASS: CLI-14b — quiet mode writes the stable raw log path"
else
  echo "FAIL: CLI-14b — quiet-mode raw-log path is missing" >&2
  fail=1
fi

if grep -q '^run_capture()' "$TARGET"; then
  echo "PASS: CLI-14c — run_capture suppression helper is present"
else
  echo "FAIL: CLI-14c — run_capture suppression helper is missing" >&2
  fail=1
fi

CONTRACT="$SCRIPT_DIR/../docs/contracts/ci-checks.cli-contract.md"
if [ -f "$CONTRACT" ]; then
  if grep -q 'CLI-14' "$CONTRACT" && grep -q '^version: 1.12' "$CONTRACT"; then
    echo "PASS: CLI-14d — contract documents CLI-14 at version 1.12"
  else
    echo "FAIL: CLI-14d — contract does not document CLI-14 at version 1.12" >&2
    fail=1
  fi
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
