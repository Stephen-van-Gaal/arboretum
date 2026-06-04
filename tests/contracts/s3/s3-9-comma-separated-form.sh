#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-9 (regression — comma-separated KV form parsing)
# pipeline-version: unified
#
# Asserts validate-build-exit.sh correctly parses the comma-separated
# KV form that log-stage.sh actually emits (`exit-status: success,
# plan: <path>, tests: green, ...`). Codex P1 reviews on PR #336
# revealed the original regex `[^[:space:]]+` was capturing trailing
# commas, causing every real `/build success` exit to be rejected as
# either an enum violation (`success,` ∉ {success, escape-hatch}) or
# a path-not-found (`<path>,` doesn't exist). Regex fix: `[^[:space:],]+`.
#
# This regression test locks the fix by using log-stage.sh's actual
# output form rather than the space-separated form the original
# fixtures used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

LOG_FIXTURE="$ROOT/tests/contracts/fixtures/build-exit-success-comma-form.txt"
SPEC_FIXTURE="$ROOT/tests/contracts/fixtures/design-good.md"

err_out=$(mktemp)
bash "$ROOT/scripts/validate-build-exit.sh" "$LOG_FIXTURE" "$SPEC_FIXTURE" 2>"$err_out"
rc=$?

assertExit 0 "$rc" "validate-build-exit accepts log-stage.sh comma form" || { cat "$err_out" >&2; rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-9"
