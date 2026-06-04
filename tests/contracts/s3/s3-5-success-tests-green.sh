#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-5
# pipeline-version: unified
#
# Asserts: a `success` /build exit's post-conditions are enforced at
# the contract layer — specifically, when the design spec's plan
# field names a file with unchecked checkboxes, validate-build-exit.sh
# refuses the success claim (drift between log-line claim and
# observable state).
#
# Note: the literal "test suite passes" check is enforced by
# ci-checks.sh as the outer gate (which runs THIS test as part of
# the contract suite). Calling ci-checks.sh from inside a contract
# test would create infinite recursion (ci-checks → smoke-test
# loop → contract runner → s3-5 → ci-checks → ...). The contract
# layer's job is to enforce that the validator refuses inconsistent
# success claims; the test-execution layer is one level up.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-success-missing-plan-check.txt"
SPEC_FIXTURE="$ROOT/tests/contracts/fixtures/design-good.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" "$SPEC_FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validator refuses success exit with unchecked plan" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S3-3" "S3-5 (post-condition enforcement)" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-5"
