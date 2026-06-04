#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-3
# pipeline-version: unified
#
# Asserts: the comment-post formatter produces exactly the shape
# documented by S9's `### Outputs` — a 2-line block with the canonical
# marker on line 1 and a parseable journey-log line on line 2. This is
# the testable proxy for the body-preservation contract until log-
# stage.sh exposes a `--body-source` flag (out-of-scope for WS4; a
# follow-up will add it for full byte-for-byte body-preservation
# testing).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Use the pure-function harness (no gh I/O).
export LOG_STAGE_TS_OVERRIDE="2026-05-24T12:00:00Z"
out=$(bash "$ROOT/scripts/log-stage.sh" --emit-log-only /design entered key=value 2>&1)
rc=$?

assertExit 0 "$rc" "log-stage.sh --emit-log-only succeeds" || exit 1

# Output must be exactly 2 lines.
line_count=$(echo "$out" | wc -l | tr -d ' ')
if [ "$line_count" -ne 2 ]; then
  echo "FAIL: S9-3 — expected 2-line output, got $line_count" >&2
  echo "$out" >&2
  exit 1
fi

# Line 1: canonical marker
line1=$(echo "$out" | sed -n '1p')
if [ "$line1" != "<!-- pipeline-state:log -->" ]; then
  echo "FAIL: S9-3 — line 1 not canonical marker (got '$line1')" >&2
  exit 1
fi

# Line 2: parseable by validate-stage-log-line.sh
tmpfile=$(mktemp)
echo "$out" > "$tmpfile"
err_out=$(mktemp)
bash "$ROOT/scripts/validate-stage-log-line.sh" "$tmpfile" 2>"$err_out"
rc=$?
rm -f "$tmpfile"
assertExit 0 "$rc" "emitted comment validates as conformant" || { rm -f "$err_out"; exit 1; }
rm -f "$err_out"

pass "S9-3"
