#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-4
# pipeline-version: unified
#
# Asserts: repeated invocations with identical inputs produce identical
# output (LWW idempotency proxy). Two --emit-log-only calls with the
# same args + a fixed timestamp must produce byte-identical output.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Fix the timestamp so two invocations produce identical output.
export LOG_STAGE_TS_OVERRIDE="2026-05-24T12:00:00Z"

out1=$(bash "$ROOT/scripts/log-stage.sh" --emit-log-only /design entered key=value 2>&1)
out2=$(bash "$ROOT/scripts/log-stage.sh" --emit-log-only /design entered key=value 2>&1)

if [ "$out1" != "$out2" ]; then
  echo "FAIL: S9-4 — repeated --emit-log-only invocations with identical args produced different output" >&2
  diff <(echo "$out1") <(echo "$out2") | sed 's/^/  /' >&2
  exit 1
fi

pass "S9-4"
