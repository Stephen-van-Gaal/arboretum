#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-5
# pipeline-version: unified
#
# Asserts: every comment the helper posts begins with the canonical
# marker followed by a parseable journey-log line per WS9 §D5.
# Tested via validate-stage-log-line.sh against good + bad fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Good fixture: accepted (exit 0)
err_out=$(mktemp)
bash "$ROOT/scripts/validate-stage-log-line.sh" "$ROOT/tests/contracts/fixtures/log-stage-comment-good.txt" 2>"$err_out"
assertExit 0 "$?" "good fixture accepted" || { rm -f "$err_out"; exit 1; }

# Bad marker: rejected
bash "$ROOT/scripts/validate-stage-log-line.sh" "$ROOT/tests/contracts/fixtures/log-stage-comment-bad-marker.txt" 2>"$err_out"
assertExit 1 "$?" "bad marker rejected" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S9-5: missing marker" "bad marker stderr" || { rm -f "$err_out"; exit 1; }

# Bad timestamp: rejected
bash "$ROOT/scripts/validate-stage-log-line.sh" "$ROOT/tests/contracts/fixtures/log-stage-comment-bad-timestamp.txt" 2>"$err_out"
assertExit 1 "$?" "bad timestamp rejected" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S9-5: timestamp" "bad timestamp stderr" || { rm -f "$err_out"; exit 1; }

# Bad action: rejected
bash "$ROOT/scripts/validate-stage-log-line.sh" "$ROOT/tests/contracts/fixtures/log-stage-comment-bad-action.txt" 2>"$err_out"
assertExit 1 "$?" "bad action rejected" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S9-2: action" "bad action stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S9-5"
