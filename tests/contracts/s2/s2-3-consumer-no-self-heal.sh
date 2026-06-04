#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-3
# pipeline-version: unified
#
# Asserts validate-design-spec.sh refuses on missing related-issue,
# naming the field in stderr — no prompting/amending/self-healing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

FIXTURE="$ROOT/tests/contracts/fixtures/design-missing-related-issue.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-design-spec.sh" "$FIXTURE" 2>"$err_out"
rc=$?

assertExit 1 "$rc" "validate-design-spec for $FIXTURE" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "related-issue: missing" "S2-3 stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S2-3"
