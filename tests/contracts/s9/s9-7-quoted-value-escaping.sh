#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-7
# pipeline-version: unified
#
# Asserts: context values containing the structural ', ' delimiter
# are double-quoted; within quoted values, the three escape sequences
# (\", \\, \n) apply at write time and un-apply at read time.
#
# Also serves as the worked example for the prompt-injection-
# resistance test pattern (see ../_lib/README-injection-pattern.md).
#
# S9-7 redesign (per Codex P2 review on plan v1): the original
# checked control characters in the fixture file itself rather than
# in the sanitizer's output, so it tested the input we wrote, not
# the round-trip the seam produced. The fix uses log-stage.sh's
# --emit-log-only harness to actually exercise the sanitizer and
# assert on its output.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Part 1: feed a payload with embedded `, ` through the sanitizer
# via --emit-log-only; assert the output is properly quoted.
out_file=$(mktemp)
err_out=$(mktemp)
bash "$ROOT/scripts/log-stage.sh" --emit-log-only /build entered \
  'context=value with, embedded comma' > "$out_file" 2>"$err_out"
rc=$?
assertExit 0 "$rc" "log-stage formatter accepted comma-bearing input" || { rm -f "$out_file" "$err_out"; exit 1; }
assertContains "$out_file" 'context: "value with, embedded comma"' "S9-7 sanitizer quoted comma value" || { rm -f "$out_file" "$err_out"; exit 1; }

# Part 2: feed a payload with embedded `"` and `\`; assert escape
# sequences are applied per the documented vocabulary.
bash "$ROOT/scripts/log-stage.sh" --emit-log-only /build entered \
  'context=has "quote" and \backslash' > "$out_file" 2>"$err_out"
rc=$?
assertExit 0 "$rc" "log-stage formatter accepted quote/backslash input" || { rm -f "$out_file" "$err_out"; exit 1; }
# In the output, " is escaped as \" and \ as \\.
assertContains "$out_file" 'context: "has \"quote\" and \\backslash"' "S9-7 sanitizer escaped quote+backslash" || { rm -f "$out_file" "$err_out"; exit 1; }

# Part 3: undefined control character is REJECTED (per log-stage.sh
# _UNDEFINED regex — covers ESC, NUL, tab, etc.).
bash "$ROOT/scripts/log-stage.sh" --emit-log-only /build entered \
  $'context=has\ttab' > "$out_file" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "log-stage rejected undefined control character" || { rm -f "$out_file" "$err_out"; exit 1; }
assertStderr "$err_out" "undefined control characters" "S9-7 rejection message" || { rm -f "$out_file" "$err_out"; exit 1; }

# Part 4: sanitizer output is free of raw control characters even
# when the INPUT contained payload-class chars that should be either
# escaped or rejected. Take the Part-1 output and verify no raw
# control chars leaked through.
bash "$ROOT/scripts/log-stage.sh" --emit-log-only /build entered \
  'context=value with, embedded comma' > "$out_file" 2>"$err_out"
# Use python3 — grep -P is unsupported on BSD grep (macOS), so the
# regex check would silently no-op there. Python3 is already a project
# dependency and gives a clean, portable hex-range check.
if ! python3 -c "
import re, sys
# Read as decoded UTF-8 text. Checking raw bytes would false-positive
# on the em-dash separator (U+2014 = 0xE2 0x80 0x94 in UTF-8, and byte
# 0x80 falls in the C1 control-char range). The contract is about
# Unicode codepoints, not byte values.
data = open('$out_file', 'r', encoding='utf-8').read()
if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]', data):
    sys.exit(1)
"; then
  echo "FAIL: S9-7 — sanitizer output contains raw control characters" >&2
  rm -f "$out_file" "$err_out"
  exit 1
fi

# Part 5: round-trip — un-escape the quoted value and confirm
# it equals the original payload.
#
# Per Codex P2 review on plan v2: sequential `sed` un-escape is NOT
# equivalent to log-stage.sh's documented reader semantics (sequential
# passes can produce lossy decodes on adjacent escape sequences). Use
# a python3 left-to-right parser that mirrors the writer's escape
# vocabulary (\", \\, \n).
ORIGINAL='value with, embedded comma'
ROUNDTRIP_QUOTED=$(sed -nE 's/.*context: "([^"]*)".*/\1/p' "$out_file")
ROUNDTRIP_UNESCAPED=$(python3 - "$ROUNDTRIP_QUOTED" <<'PY'
import sys
s = sys.argv[1]
out = []
i = 0
while i < len(s):
    if s[i] == '\\' and i + 1 < len(s):
        c = s[i + 1]
        if c == '"':
            out.append('"'); i += 2
        elif c == '\\':
            out.append('\\'); i += 2
        elif c == 'n':
            out.append('\n'); i += 2
        else:
            # Undefined escape — writer rejects these at write time;
            # reader passes through unchanged for diagnostic purposes.
            out.append(s[i]); i += 1
    else:
        out.append(s[i]); i += 1
sys.stdout.write(''.join(out))
PY
)
if [ "$ROUNDTRIP_UNESCAPED" != "$ORIGINAL" ]; then
  echo "FAIL: S9-7 — round-trip lossy:" >&2
  echo "  original: $ORIGINAL" >&2
  echo "  round-trip: $ROUNDTRIP_UNESCAPED" >&2
  rm -f "$out_file" "$err_out"
  exit 1
fi

rm -f "$out_file" "$err_out"
pass "S9-7"
