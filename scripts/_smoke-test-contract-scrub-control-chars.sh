#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-scrub-control-chars.sh - Contract test for
# docs/contracts/scrub-control-chars.contract.md (seam: scrub-control-chars).
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/lib/scrub-control-chars.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER not found" >&2; exit 1; }

# shellcheck source=/dev/null
. "$HELPER"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }
  fail=1
}

# ---------------------------------------------------------------------------
# SCC-1: bash↔python byte-identity over every byte 0x00-0xff (+ ASCII sample).
# The bash `scrub_control_chars` (tr) output must equal python
# re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", x) byte-for-byte.
# ---------------------------------------------------------------------------
python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)) + b"hello\tworld\n")' > "$FIX/corpus"

scrub_control_chars < "$FIX/corpus" > "$FIX/bash_out"

[ -n "${ARBO_CTRL_CHAR_CLASS:-}" ] || fail_case "SCC-1 setup: ARBO_CTRL_CHAR_CLASS not exported by helper"

ARBO_CTRL_CHAR_CLASS="$ARBO_CTRL_CHAR_CLASS" python3 - "$FIX/corpus" "$FIX/py_out" <<'PY'
import os, re, sys
data = open(sys.argv[1], "rb").read().decode("latin-1")
out = re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", data)
open(sys.argv[2], "wb").write(out.encode("latin-1"))
PY

if cmp -s "$FIX/bash_out" "$FIX/py_out"; then
  pass "SCC-1 bash↔python byte-identity over 0x00-0xff"
else
  fail_case "SCC-1 byte-identity mismatch" "$(cmp "$FIX/bash_out" "$FIX/py_out" 2>&1; echo; echo bash:; od -c "$FIX/bash_out" | head; echo py:; od -c "$FIX/py_out" | head)"
fi

# Canonical scrub must PRESERVE tab/newline/CR. Compare with cmp against a fixture
# file (dependency-free) — NOT xxd, which may be absent and would let an empty-vs-
# empty comparison pass vacuously (Codex P2 on #679).
printf 'a\tb\nc\rd' | scrub_control_chars > "$FIX/ws_out"
printf 'a\tb\nc\rd' > "$FIX/ws_expected"
if cmp -s "$FIX/ws_out" "$FIX/ws_expected"; then
  pass "SCC-1b scrub_control_chars preserves \\t \\n \\r"
else
  fail_case "SCC-1b scrub_control_chars altered whitespace" "$(od -c "$FIX/ws_out" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# SCC-2: oneline variant additionally removes \t \n \r.
# ---------------------------------------------------------------------------
got=$(printf 'a\tb\nc\rd' | scrub_control_chars_oneline)
if [ "$got" = "abcd" ]; then
  pass "SCC-2 scrub_control_chars_oneline strips \\t \\n \\r"
else
  fail_case "SCC-2 oneline did not flatten whitespace" "got: $(printf '%s' "$got" | od -c)"
fi

# ---------------------------------------------------------------------------
# SCC-3: enforcement grep-guard — no source file re-inlines the raw control-char
# class or the tr control set, outside the helper and this test. This is the
# line that retires the documented-but-unenforced "canonical pattern."
# ---------------------------------------------------------------------------
# Patterns that indicate an inlined copy of the scrub byte-set.
# Production sites only. Notes:
#  - The class pattern requires the closing `]` immediately after `\x9f`, so it
#    matches the EXACT canonical scrub class and NOT supersets that share the
#    substring — e.g. log-stage.sh's `_UNDEFINED` validator class
#    `[...\x7f-\x9f\t]` is a `.search`-based escape-vocabulary validator, a
#    distinct concern that must not be forced onto the scrub primitive (#672).
#  - The helper itself and any _smoke-test-* file are excluded (tests reference
#    the byte-set in fixtures/assertions).
re_inlines=$(grep -rEl \
  -e '\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f-\\x9f\]' \
  -e 'tr -d .\\000-\\0(10|37)' \
  "$ROOT/scripts" "$ROOT/.claude/hooks" 2>/dev/null \
  | grep -vE '/scrub-control-chars\.sh$' \
  | grep -vE '/_smoke-test-' \
  || true)

if [ -z "$re_inlines" ]; then
  pass "SCC-3 no source file re-inlines the scrub byte-set"
else
  fail_case "SCC-3 inlined scrub copies remain (migrate to scrub-control-chars.sh)" "$re_inlines"
fi

if [ "$fail" -ne 0 ]; then
  echo "scrub-control-chars contract: FAIL" >&2
  exit 1
fi
echo "scrub-control-chars contract: PASS"
