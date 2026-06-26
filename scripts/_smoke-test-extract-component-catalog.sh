#!/usr/bin/env bash
# owner: extract-shared-component
# scope: plugin-only
# ci-parallel: serial
# Contract test for the extract-component catalog schema: the survey-phase
# producer format must satisfy the validator the extract phase relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VALIDATE="skills/extract-component/scripts/validate-catalog.sh"
FIX="tests/fixtures/extract-component"
fail=0

expect_ok() {  # expect_ok <file> <label>
  if bash "$VALIDATE" "$1" >/dev/null 2>&1; then echo "PASS: $2"; else echo "FAIL: $2" >&2; fail=1; fi
}
expect_reject() {  # expect_reject <file> <label>
  if bash "$VALIDATE" "$1" >/dev/null 2>&1; then echo "FAIL: $2" >&2; fail=1; else echo "PASS: $2"; fi
}

expect_ok     "$FIX/catalog-good.md"               "good catalog validates"
expect_reject "$FIX/catalog-bad-missing-field.md"  "missing required field rejected"
expect_reject "$FIX/catalog-bad-enum.md"           "invalid worth_extracting enum rejected"

if [ "$fail" -ne 0 ]; then echo "CATALOG CONTRACT TEST FAILED" >&2; exit 1; fi
echo "all catalog contract checks passed"
