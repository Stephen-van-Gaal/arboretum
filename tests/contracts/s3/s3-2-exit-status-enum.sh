#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-2
# pipeline-version: v2
#
# Asserts validate-build-exit.sh rejects exit-status values outside
# the closed enum {success, escape-hatch}.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-bad-status-enum.txt"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-build-exit for $LOG_FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S3-2: exit-status value not in" "S3-2 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-2"
