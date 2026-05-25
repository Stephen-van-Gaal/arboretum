#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-5
# pipeline-version: v2
#
# Asserts cross-field invariant: plan: null is incompatible with
# implementation-mode: executing-plans (executing-plans requires a plan file).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

FIXTURE="$ROOT/tests/contracts/fixtures/design-plan-null-with-executing-plans.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-design-spec.sh" "$FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-design-spec for $FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "plan: null is incompatible with implementation-mode: executing-plans" "S2-5 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S2-5"
