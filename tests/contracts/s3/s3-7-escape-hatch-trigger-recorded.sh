#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-7
# pipeline-version: unified
#
# Asserts validate-build-exit.sh rejects an escape-hatch exit when
# the design spec lacks the `escape-hatch:` trigger block.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-escape-hatch-no-trigger.txt"
SPEC_FIXTURE="$ROOT/tests/contracts/fixtures/design-good.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" "$SPEC_FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-build-exit for $LOG_FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S3-7: design spec missing 'escape-hatch:' block" "S3-7 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-7"
