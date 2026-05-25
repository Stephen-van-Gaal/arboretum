#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-6
# pipeline-version: v2
#
# Asserts that when plan: is a path, the file must exist; pointing at
# a missing file is rejected.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

FIXTURE="$ROOT/tests/contracts/fixtures/design-plan-missing-file.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-design-spec.sh" "$FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-design-spec for $FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "plan: file not found" "S2-6 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S2-6"
