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

[ -f "$TARGET" ] || { echo "FAIL: ci-checks.sh not found at $TARGET" >&2; exit 1; }

fail=0

# ---------------------------------------------------------------------------
# CLI-1: Stage-banner sequence
# All six banners must be present and appear in the documented order.
# ---------------------------------------------------------------------------
BANNERS=(
  "=== ShellCheck ==="
  "=== Smoke tests ==="
  "=== Cross-reference validation ==="
  "=== Contract coverage validation ==="
  "=== Health check (non-blocking) ==="
  "=== Version bump check ==="
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
[ "$fail" -eq 0 ] && echo "PASS: CLI-1 — all six stage banners present and in order"

# ---------------------------------------------------------------------------
# CLI-2: fail-flag accumulation — blocking stages use `|| fail=1`
# The script must initialise fail=0 and accumulate via || fail=1.
# The health-check line must NOT have || fail=1 (non-blocking).
# ---------------------------------------------------------------------------
if ! grep -q '^fail=0' "$TARGET"; then
  echo "FAIL: CLI-2 — 'fail=0' initialisation not found" >&2
  fail=1
else
  echo "PASS: CLI-2a — fail=0 initialisation present"
fi

# Count lines containing `|| fail=1` (must be at least 4: shellcheck, smoke loop, cross-ref, contract-coverage, version-bump)
fail1_count=$(grep -c '|| fail=1' "$TARGET" || true)
if [ "$fail1_count" -lt 4 ]; then
  echo "FAIL: CLI-2 — expected ≥4 '|| fail=1' accumulations, found $fail1_count" >&2
  fail=1
else
  echo "PASS: CLI-2b — found $fail1_count '|| fail=1' accumulations (≥4)"
fi

# Health-check line must absorb its exit code, not set fail=1
health_line=$(grep "health-check.sh" "$TARGET" | grep -v "^#" | head -1)
if echo "$health_line" | grep -q '|| fail=1'; then
  echo "FAIL: CLI-2 — health-check line sets fail=1; it must be non-blocking" >&2
  fail=1
else
  echo "PASS: CLI-2c — health-check is non-blocking (no '|| fail=1' on health-check line)"
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
# Final result
# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
