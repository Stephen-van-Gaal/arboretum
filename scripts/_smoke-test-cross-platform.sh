#!/usr/bin/env bash
# owner: cross-platform-support
# scope: any
# _smoke-test-cross-platform.sh — guards arboretum's cross-platform support
# contract (docs/specs/cross-platform-support.spec.md): framework scripts must
# read/write text as UTF-8 regardless of host locale, and must tolerate CRLF in
# parsed input. The guard self-forces a hostile environment rather than relying
# on a Windows CI runner: a non-UTF-8 locale with Python's C-locale UTF-8
# coercion disabled (PEP 538/540), plus CRLF fixtures. This reproduces the
# Windows failure mechanism deterministically on ubuntu. Covers #847 (the three
# fixes) and #851 (the CI guard).
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# journey_render.py reads ARBO_CTRL_CHAR_CLASS at import (env bridge).
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/scrub-control-chars.sh"

# The hostile environment: a non-UTF-8 locale, with both of Python's automatic
# C-locale-to-UTF-8 escape hatches disabled, so default text I/O resolves to
# ASCII — exactly what breaks on a Windows cp1252 / POSIX-C host.
HOSTILE=(env LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0)

# A non-ASCII payload that must survive a UTF-8 round-trip: em dash, en dash,
# smart quotes, CJK. ASCII-only content would not exercise the contract.
NONASCII=$'em — en – “quote” 中文'

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- detail ---" >&2; printf '%s\n' "$2" >&2; }
  fail=1
}

# ---------------------------------------------------------------------------
# CP-0: self-check the hostile environment. The whole guard is worthless if the
# env does not actually resolve to a non-UTF-8 codec — on a libc/container where
# the C locale is itself UTF-8, a reverted fix would silently still pass. Assert
# up front that the hostile env yields a non-UTF-8 stdout encoding.
# ---------------------------------------------------------------------------
enc="$("${HOSTILE[@]}" python3 -c 'import sys; print(sys.stdout.encoding)' 2>&1)"
case "$(printf '%s' "$enc" | tr 'A-Z' 'a-z' | tr -d '-')" in
  utf8) fail_case "CP-0 hostile env yields a UTF-8 codec ('$enc') — the guard would false-pass; CP-1..CP-5 prove nothing here" ;;
  *) pass "CP-0 hostile env yields a non-UTF-8 stdout encoding ($enc)" ;;
esac

# ---------------------------------------------------------------------------
# CP-1: journey_render.py reads UTF-8 transcripts under a hostile locale.
# last_ts() is representative of all three identical `open()` handlers (L72,
# L104, L288). Without encoding="utf-8", `for line in f` decodes as ASCII and
# raises UnicodeDecodeError on the first non-ASCII byte, aborting the render.
# ---------------------------------------------------------------------------
printf '{"timestamp": "2026-06-13T120000Z", "label": "%s"}\n' "$NONASCII" > "$FIX/tx.jsonl"
got="$("${HOSTILE[@]}" ROOT="$ROOT" python3 - "$FIX/tx.jsonl" 2>&1 <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "scripts", "lib"))
import journey_render as J
print(J.last_ts(sys.argv[1]))
PY
)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "2026-06-13T120000Z" ]; then
  pass "CP-1 journey_render reads UTF-8 transcript under non-UTF-8 locale"
else
  fail_case "CP-1 journey_render mis-decodes UTF-8 transcript under non-UTF-8 locale (rc=$rc)" "$got"
fi

# ---------------------------------------------------------------------------
# CP-2: yaml-lite.sh emits non-ASCII frontmatter values under a hostile locale.
# The file read is already encoding-explicit; the exposure is stdout — print()
# of a non-ASCII value to an ASCII stdout raises UnicodeEncodeError. PYTHONUTF8=1
# on the python3 invocation forces UTF-8 stdout regardless of host locale.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/yaml-lite.sh"
printf -- '---\nlabel: %s\n---\n' "$NONASCII" > "$FIX/fm.md"
out="$("${HOSTILE[@]}" bash -c '. "$1"; yaml_lite_parse frontmatter "$2"' _ "$ROOT/scripts/lib/yaml-lite.sh" "$FIX/fm.md" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "label=$NONASCII" ]; then
  pass "CP-2 yaml-lite emits non-ASCII frontmatter value under non-UTF-8 locale"
else
  fail_case "CP-2 yaml-lite fails on non-ASCII frontmatter value under non-UTF-8 locale (rc=$rc)" "$out"
fi

# ---------------------------------------------------------------------------
# CP-3: generate-register.sh parses a CRLF-terminated spec. The frontmatter
# fence test is `[[ "$line" == "---" ]]`; a CRLF fence is "---\r", which never
# matches, so the spec's frontmatter is never extracted and the whole spec is
# silently dropped from REGISTER.md. (Byte-level, so locale-independent.)
# ---------------------------------------------------------------------------
mkdir -p "$FIX/proj/docs/specs"
# CRLF fences plus a non-ASCII value in an owned-path entry — exercises both the
# fence match and CR-freedom of parsed values.
printf -- '---\r\nname: crlfprobe\r\nstatus: active\r\nowner: crlfprobe\r\nowns:\r\n  - scripts/crlf\xe2\x80\x94probe.sh\r\n---\r\n\r\n# CRLF probe\r\n' \
  > "$FIX/proj/docs/specs/crlfprobe.spec.md"
reg="$(bash "$ROOT/scripts/generate-register.sh" "$FIX/proj" --dry-run 2>/dev/null)"
# The spec must not be dropped, AND no stray CR may survive into any parsed
# field. grep 'crlfprobe' alone only proves the filename column is present
# (generate-register emits the basename) — assert CR-freedom separately so a
# regression that strips \r on the fence but leaks it into values still fails.
if ! printf '%s' "$reg" | grep -q 'crlfprobe'; then
  fail_case "CP-3 generate-register drops CRLF-terminated spec from REGISTER" "$reg"
elif printf '%s' "$reg" | grep -q $'\r'; then
  fail_case "CP-3 generate-register leaks a stray CR into REGISTER output" "$(printf '%s' "$reg" | grep $'\r' | cat -v)"
else
  pass "CP-3 generate-register parses CRLF-terminated spec with no stray CR"
fi

# ---------------------------------------------------------------------------
# CP-4: read-session-journey.sh writes AND prints a report that contains the
# non-ASCII subagent glyph "⤷" (journey_render.py). The renderer's reads are
# encoding-explicit, but the caller heredoc writes (open(path,'w')) and prints
# the report — so the write/print half must force UTF-8 too. A transcript with a
# subagent puts "⤷ Agent:" in the report; under a non-UTF-8 locale the write/
# print raises UnicodeEncodeError unless the caller sets PYTHONUTF8=1.
# ---------------------------------------------------------------------------
mkdir -p "$FIX/rsj/sess/subagents"
cat > "$FIX/rsj/sess.jsonl" <<'JSONL'
{"uuid":"u1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"m1","model":"claude-opus-4","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"arboretum:design"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
JSONL
cat > "$FIX/rsj/sess/subagents/agent-child.jsonl" <<'JSONL'
{"uuid":"c1","parentUuid":"u1","attributionAgent":"general-purpose","message":{"id":"cm1","model":"claude-opus-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}}}
JSONL
rsj_out="$("${HOSTILE[@]}" ARBORETUM_STATE_DIR="$FIX/rsj/.arboretum" bash "$ROOT/scripts/read-session-journey.sh" --transcript "$FIX/rsj/sess.jsonl" --stdout 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$rsj_out" | grep -q 'Agent:general-purpose'; then
  pass "CP-4 read-session-journey writes/prints non-ASCII report under non-UTF-8 locale"
else
  fail_case "CP-4 read-session-journey crashes writing/printing non-ASCII report under non-UTF-8 locale (rc=$rc)" "$rsj_out"
fi

# ---------------------------------------------------------------------------
# CP-5: render-ledger-journey.sh reads the push ledger with a bare open(ledger)
# and writes/prints a report the same way as read-session-journey. A ledger row
# carrying a non-ASCII value makes the read raise UnicodeDecodeError under a
# non-UTF-8 locale unless the caller sets PYTHONUTF8=1.
# ---------------------------------------------------------------------------
led="$FIX/ledger.jsonl"
printf '{"issue":852,"stage":"/build","ts":"2026-06-13T120000Z","label":"%s"}\n' "$NONASCII" > "$led"
rlj_out="$("${HOSTILE[@]}" ARBORETUM_STATE_DIR="$FIX/rlj/.arboretum" bash "$ROOT/scripts/render-ledger-journey.sh" --ledger "$led" --stdout 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "CP-5 render-ledger-journey reads a non-ASCII ledger under non-UTF-8 locale"
else
  fail_case "CP-5 render-ledger-journey crashes reading non-ASCII ledger under non-UTF-8 locale (rc=$rc)" "$rlj_out"
fi

[ "$fail" -eq 0 ] || { echo "cross-platform smoke: FAILED" >&2; exit 1; }
echo "cross-platform smoke: all checks passed"
