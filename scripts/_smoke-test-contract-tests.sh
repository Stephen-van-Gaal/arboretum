#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-tests.sh — Run every test under tests/contracts/
# whose declared pipeline-version matches the active flag.
#
# Conventions:
#   - Tests live at tests/contracts/<seam>/<id>.sh (excluding _lib/ and
#     fixtures/).
#   - Each test declares its applicable pipeline version in a header
#     comment: `# pipeline-version: v1 | v2 | any`. Missing header is a
#     warning (test still runs as `any`); fix by adding the header.
#   - Runner reads the active flag via scripts/read-pipeline-flag.sh.
#   - Tests are executed via plain `bash "$test_file"` and inherit the
#     strictness their own shebang declares (the project convention is
#     `set -uo pipefail` per the test template). Non-zero exit = fail.
#   - _lib/test_assert.sh (the assert.sh helper smoke test) is invoked
#     explicitly before the contract-test loop — it's a unit test of
#     the helpers, not a contract test, and the loop skips _lib/ by
#     design.
#
# Exit codes:
#   0 — all applicable tests passed
#   1 — at least one test failed
#   2 — invocation problem (missing dir, flag-lookup failure)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT/tests/contracts"

if [ ! -d "$TESTS_DIR" ]; then
  echo "ERROR: tests/contracts/ not found at $TESTS_DIR" >&2
  exit 2
fi

# Fail closed on flag-lookup error. Running under `set -u` (not `-e`), a
# silent substitution failure would leave FLAG empty, and every versioned
# contract test would be treated as a `any`-match → falsely-running tests
# that should have been skipped. Explicit check + non-zero exit.
if ! FLAG=$(cd "$ROOT" && bash scripts/read-pipeline-flag.sh 2>&1); then
  echo "ERROR: scripts/read-pipeline-flag.sh failed; refusing to run contract tests" >&2
  echo "$FLAG" >&2
  exit 2
fi
if [ -z "$FLAG" ]; then
  echo "ERROR: scripts/read-pipeline-flag.sh produced empty output; refusing to run contract tests" >&2
  exit 2
fi
echo "=== Contract tests (pipeline.workflow=$FLAG) ==="

FAILED=0
RAN=0
SKIPPED=0

# Pre-flight: run the assert.sh helper smoke test. The contract-test
# loop skips _lib/ (it's library code, not contract-test files), but
# the helpers need their own regression check — silently skipping it
# would leave assert helper regressions undetectable in CI.
echo "--- _lib/test_assert.sh (helper regression check) ---"
if ! bash "$TESTS_DIR/_lib/test_assert.sh"; then
  echo "FAIL: _lib/test_assert.sh — assert.sh helpers have regressed" >&2
  FAILED=$((FAILED + 1))
fi

# Iterate over .sh files under tests/contracts/, excluding _lib/ and
# fixtures/. Use `find` (not `shopt -s globstar`) — globstar requires
# Bash 4+, and macOS's system /bin/bash is 3.2 where the option is
# rejected. `find` is POSIX-portable.
while IFS= read -r test_file; do
  [ -z "$test_file" ] && continue
  case "$test_file" in
    */_lib/*|*/fixtures/*) continue ;;
  esac

  # Extract pipeline-version header. Missing header = warning + treat
  # as `any` (per the conventions comment above).
  version=$(grep -m1 -E '^# pipeline-version:' "$test_file" | sed -E 's/^# pipeline-version:[[:space:]]*//')
  if [ -z "$version" ]; then
    echo "WARN ${test_file#"$ROOT/"} — missing '# pipeline-version:' header (defaulting to any)" >&2
    version="any"
  fi

  if [ "$version" != "any" ] && [ "$version" != "$FLAG" ]; then
    SKIPPED=$((SKIPPED + 1))
    echo "SKIP ($version) ${test_file#"$ROOT/"}"
    continue
  fi

  RAN=$((RAN + 1))
  rel="${test_file#"$ROOT/"}"
  # Run each test with its own strictness (declared in the test's
  # shebang/set line — typically `set -uo pipefail`). Adding `bash -e`
  # here would over-strict tests that intentionally tolerate non-zero
  # exits in sub-commands (mktemp cleanup branches, optional grep
  # misses, etc.) — that's the test author's design choice, not the
  # runner's to override.
  if out=$(bash "$test_file" 2>&1); then
    echo "PASS $rel"
  else
    rc=$?
    FAILED=$((FAILED + 1))
    echo "FAIL $rel (exit $rc)"
    echo "$out" | sed 's/^/    /'
  fi
done < <(find "$TESTS_DIR" -type f -name '*.sh' | sort)

echo "=== Contract tests: $RAN ran, $FAILED failed, $SKIPPED skipped ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
