#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-1
# pipeline-version: v2
#
# Asserts validate-design-spec.sh accepts a complete, valid design spec
# (all 5 required frontmatter fields present + valid enums + plan-file exists).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

FIXTURE="$ROOT/tests/contracts/fixtures/design-good.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-design-spec.sh" "$FIXTURE" 2>"$err_out"
rc=$?

assertExit 0 "$rc" "validate-design-spec for $FIXTURE" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S2-1"
