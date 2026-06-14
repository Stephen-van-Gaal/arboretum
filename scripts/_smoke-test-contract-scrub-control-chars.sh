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
# SCC-1: bash↔python EQUIVALENCE over a UTF-8 corpus (codepoint model, #799).
#
# The scrub is codepoint-aware, not byte-wise: it strips the C0/C1 *control
# codepoints* while preserving every other valid UTF-8 codepoint (em dash, smart
# quotes, emoji). The old SCC-1 asserted byte-identity using a latin-1 decode —
# that model treated each byte as a codepoint and is incompatible with codepoint
# stripping (it would "pass" only a byte-wise scrub, which corrupts multibyte
# UTF-8). Redesigned to assert that the bash `scrub_control_chars` (which routes
# through the python3 surrogateescape codepoint scrub) and the python env-bridge consumer
# `re.sub(ARBO_CTRL_CHAR_CLASS, "", text)` agree over a UTF-8 corpus that mixes
# multibyte chars with the C0/C1 control codepoints — decoding/encoding as UTF-8
# on both sides. Intent preserved: the two runtimes must produce the same result
# for the same author-controlled string.
# ---------------------------------------------------------------------------
# Corpus: ASCII, tab/newline/CR (preserved by scrub_control_chars), the full C0
# control set + 0x7f (single-byte, stripped), the full C1 set U+0080-U+009F
# (2-byte c2 80..c2 9f, stripped), and a spread of valid multibyte codepoints
# that MUST survive: em dash U+2014, en dash U+2013, smart quotes U+201C/U+201D,
# NBSP U+00A0 (c2 a0 — adjacent to C1 but valid), CJK, emoji.
python3 - "$FIX/corpus" <<'PY'
import sys
parts = []
parts.append("ascii hello\tworld\n")
parts.append("c0:" + "".join(chr(c) for c in list(range(0x00, 0x09)) + [0x0b, 0x0c] + list(range(0x0e, 0x20)) + [0x7f]))
parts.append("c1:" + "".join(chr(c) for c in range(0x80, 0xa0)))
parts.append("keep: do — thing – “quoted”  NBSP 中文 \U0001F600 end")
open(sys.argv[1], "wb").write("".join(parts).encode("utf-8"))
PY

scrub_control_chars < "$FIX/corpus" > "$FIX/bash_out"

[ -n "${ARBO_CTRL_CHAR_CLASS:-}" ] || fail_case "SCC-1 setup: ARBO_CTRL_CHAR_CLASS not exported by helper"

# Python consumers operate on UTF-8-decoded text (str), as production heredocs do
# (json.load / open(encoding="utf-8")). Decode the corpus as UTF-8, scrub on
# codepoints, re-encode as UTF-8 for the byte-comparison against bash.
ARBO_CTRL_CHAR_CLASS="$ARBO_CTRL_CHAR_CLASS" python3 - "$FIX/corpus" "$FIX/py_out" <<'PY'
import os, re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8")
out = re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", text)
open(sys.argv[2], "wb").write(out.encode("utf-8"))
PY

if cmp -s "$FIX/bash_out" "$FIX/py_out"; then
  pass "SCC-1 bash↔python equivalence over UTF-8 corpus (codepoint model)"
else
  fail_case "SCC-1 bash↔python mismatch on UTF-8 corpus" "$(cmp "$FIX/bash_out" "$FIX/py_out" 2>&1; echo; echo bash:; od -c "$FIX/bash_out" | head -20; echo py:; od -c "$FIX/py_out" | head -20)"
fi

# ---------------------------------------------------------------------------
# SCC-1c: codepoint-aware UTF-8 preservation + control stripping (#799).
# Direct assertions on scrub_control_chars: valid multibyte content round-trips
# byte-for-byte; C0 and C1 control codepoints are removed.
# ---------------------------------------------------------------------------
# Em dash round-trip: 'do <U+2014> thing' (e2 80 94) must survive intact — the
# regression that motivated #799 (byte-wise tr deleted the 0x80/0x94 bytes).
printf 'do \xe2\x80\x94 thing' | scrub_control_chars > "$FIX/em_out"
printf 'do \xe2\x80\x94 thing' > "$FIX/em_expected"
if cmp -s "$FIX/em_out" "$FIX/em_expected"; then
  pass "SCC-1c em-dash (U+2014) round-trips intact"
else
  fail_case "SCC-1c em-dash corrupted" "$(od -An -tx1 "$FIX/em_out" 2>/dev/null)"
fi

# Smart quotes + emoji round-trip.
printf '\xe2\x80\x9chi\xe2\x80\x9d \xf0\x9f\x98\x80' | scrub_control_chars > "$FIX/uni_out"
printf '\xe2\x80\x9chi\xe2\x80\x9d \xf0\x9f\x98\x80' > "$FIX/uni_expected"
if cmp -s "$FIX/uni_out" "$FIX/uni_expected"; then
  pass "SCC-1c smart-quote + emoji round-trip intact"
else
  fail_case "SCC-1c smart-quote/emoji corrupted" "$(od -An -tx1 "$FIX/uni_out" 2>/dev/null)"
fi

# NBSP (U+00A0 = c2 a0) is adjacent to the C1 range but valid — must survive.
printf 'a\xc2\xa0b' | scrub_control_chars > "$FIX/nbsp_out"
printf 'a\xc2\xa0b' > "$FIX/nbsp_expected"
if cmp -s "$FIX/nbsp_out" "$FIX/nbsp_expected"; then
  pass "SCC-1c NBSP (U+00A0) preserved (not mistaken for C1)"
else
  fail_case "SCC-1c NBSP corrupted" "$(od -An -tx1 "$FIX/nbsp_out" 2>/dev/null)"
fi

# C0 control stripping (ESC/ANSI vector): ESC + CSI '[31m' + BEL removed.
got=$(printf 'a\x1b[31mX\x07b' | scrub_control_chars)
if [ "$got" = "a[31mXb" ]; then
  pass "SCC-1c C0 controls (ESC 0x1b, BEL 0x07) stripped"
else
  fail_case "SCC-1c C0 not stripped" "got: $(printf '%s' "$got" | od -c)"
fi

# C1 codepoint stripping: U+009B CSI (c2 9b) and U+0080 (c2 80) removed as
# codepoints, surrounding ASCII kept.
printf 'a\xc2\x9bb\xc2\x80c' | scrub_control_chars > "$FIX/c1_out"
printf 'abc' > "$FIX/c1_expected"
if cmp -s "$FIX/c1_out" "$FIX/c1_expected"; then
  pass "SCC-1c C1 codepoints (U+009B CSI, U+0080) stripped as 2-byte sequences"
else
  fail_case "SCC-1c C1 not stripped" "$(od -An -tx1 "$FIX/c1_out" 2>/dev/null)"
fi

# Invalid-UTF-8 input policy (#799): author-controlled bytes may be invalid UTF-8
# (e.g. a malformed branch name). Policy = strip the dangerous control bytes/
# codepoints (C0, 0x7f, C1) whether they arrive as valid codepoints OR as raw
# orphan bytes; pass every NON-control byte through unchanged; never crash.
# Here: ESC 0x1b (C0) and a raw orphan 0x80 (C1, no 0xc2 lead) are stripped; the
# non-control invalid byte 0xff passes through.
printf 'a\x80\x1b\xffb' | scrub_control_chars > "$FIX/inv_out"
printf 'a\xffb' > "$FIX/inv_expected"   # 0x1b + raw 0x80 stripped; 0xff passes through
if cmp -s "$FIX/inv_out" "$FIX/inv_expected"; then
  pass "SCC-1c invalid-UTF-8: C0 + raw orphan C1 stripped, non-control bytes passthrough (no crash)"
else
  fail_case "SCC-1c invalid-UTF-8 policy violated" "$(od -An -tx1 "$FIX/inv_out" 2>/dev/null)"
fi

# Raw orphan C1 byte security case (mirrors workspace-context WSC-10): a bare
# 0x9b byte is C1 CSI to an 8-bit/Latin-1 terminal and must be stripped even
# though it is not valid UTF-8 and not the c2 9b sequence.
printf 'up\x9bX' | scrub_control_chars > "$FIX/rawc1_out"
printf 'upX' > "$FIX/rawc1_expected"
if cmp -s "$FIX/rawc1_out" "$FIX/rawc1_expected"; then
  pass "SCC-1c raw orphan C1 byte (0x9b CSI) stripped (8-bit-terminal defense)"
else
  fail_case "SCC-1c raw orphan C1 byte not stripped" "$(od -An -tx1 "$FIX/rawc1_out" 2>/dev/null)"
fi

# No-trailing-newline faithfulness: scrub must not append a newline (the C1 pass
# must be stream-faithful, not line-oriented). Regression guard for the sed pass.
printf 'abc' | scrub_control_chars > "$FIX/nonl_out"
printf 'abc' > "$FIX/nonl_expected"
if cmp -s "$FIX/nonl_out" "$FIX/nonl_expected"; then
  pass "SCC-1c scrub does not append a trailing newline"
else
  fail_case "SCC-1c scrub appended/altered trailing newline" "$(od -An -tx1 "$FIX/nonl_out" 2>/dev/null)"
fi

# python3-free fallback (#799): when python3 is absent, scrub_control_chars falls
# back to a byte-wise tr strip. It does NOT preserve multibyte UTF-8 (degraded),
# but MUST still strip every dangerous control byte — the security floor that the
# session-start no-python3 banner branch (SSB-5c) depends on. Verify C0 (ESC) and
# raw C1 (0x9b) are removed when python3 is masked off PATH.
NOPY="$FIX/nopy-bin"
mkdir -p "$NOPY"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = python3 ] && continue
    [ -e "$NOPY/$_b" ] || ln -s "$_f" "$NOPY/$_b" 2>/dev/null || true
  done
done
got=$(PATH="$NOPY" bash -c '. "'"$HELPER"'"; printf "a\x1b[31mb\x9bc\x07d" | scrub_control_chars')
if [ "$got" = "a[31mbcd" ]; then
  pass "SCC-1c python3-free fallback strips C0 + raw C1 (security floor)"
else
  fail_case "SCC-1c python3-free fallback failed to strip controls" "got: $(printf '%s' "$got" | od -An -tx1)"
fi

# oneline variant must also be codepoint-aware (em dash survives, C1 stripped).
# Input 'x <U+2014> <U+009B> y' → C1 removed, em dash kept, \t\n\r already absent.
printf 'x \xe2\x80\x94 \xc2\x9b y' | scrub_control_chars_oneline > "$FIX/ol_out"
printf 'x \xe2\x80\x94  y' > "$FIX/ol_expected"
if cmp -s "$FIX/ol_out" "$FIX/ol_expected"; then
  pass "SCC-1c oneline is codepoint-aware (em dash kept, C1 stripped)"
else
  fail_case "SCC-1c oneline not codepoint-aware" "$(od -An -tx1 "$FIX/ol_out" 2>/dev/null)"
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
