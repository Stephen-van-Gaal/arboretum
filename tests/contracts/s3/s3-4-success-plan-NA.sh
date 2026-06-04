#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-4
# pipeline-version: unified
#
# Asserts validate-build-exit.sh accepts a `success` exit with plan:null
# (the plan-checkbox check is exempt under null-mode by S3-4 design).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-success-plan-null.txt"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" 2>"$err_out"
rc=$?

assertExit 0 "$rc" "validate-build-exit accepts success + plan:null" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-4"
