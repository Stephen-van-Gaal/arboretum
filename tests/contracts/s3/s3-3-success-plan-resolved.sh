#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-3
# pipeline-version: v2
#
# Asserts validate-build-exit.sh rejects a `success` exit whose
# referenced plan has unchecked checkboxes without a (skipped: <reason>)
# marker — the post-condition check in path-mode plans.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-success-missing-plan-check.txt"
SPEC_FIXTURE="$ROOT/tests/contracts/fixtures/design-good.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" "$SPEC_FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-build-exit for $LOG_FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S3-3: 1 unchecked plan checkbox" "S3-3 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-3"
