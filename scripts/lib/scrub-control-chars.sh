#!/usr/bin/env bash
# owner: shared-components
# scope: plugin-only
# scrub-control-chars.sh - Single source of the control-char scrub primitive.
#
# Strips ASCII/C1 control characters from author-controlled content (branch
# names, issue titles, PR metadata, paths) before it enters Claude's context,
# blocking ANSI/terminal-escape injection (CLAUDE.md § Defense in depth).
#
# Sourced, never executed. Two runtimes share one canonical codepoint set:
#   - bash consumers source this file and pipe through the functions below.
#   - python heredocs embedded in .sh scripts read ARBO_CTRL_CHAR_CLASS via
#     os.environ and compile it (the env bridge — extraction-rule.md rule 1).
#
# Canonical control set (CODEPOINTS, not bytes):
#   C0 + DEL: U+0000-U+0008, U+000B, U+000C, U+000E-U+001F, U+007F
#   C1:       U+0080-U+009F   (defense-in-depth: e.g. U+009B CSI)
# (preserves \t \n \r). The `_oneline` variant additionally removes \t \n \r
# for single-line display (e.g. the boot banner).
#
# CODEPOINT-AWARE, NOT BYTE-WISE (#799). The scrub must operate on Unicode
# codepoints so that valid multibyte UTF-8 (em dash U+2014 = e2 80 94, smart
# quotes, NBSP U+00A0 = c2 a0, emoji) round-trips intact. The original
# implementation stripped the raw 0x7f-0x9f *byte* range with `LC_ALL=C tr -d`;
# because 0x80-0x9f is also the UTF-8 continuation-byte range, that deleted bytes
# mid-codepoint and corrupted any multibyte text.
#
# Why a `tr`/`sed` byte pipeline cannot do this correctly: the security model
# (see SCC / WSC-10) requires stripping a C1 control BOTH when it appears as the
# valid 2-byte UTF-8 sequence (c2 8x/9x) AND as a raw orphan byte 0x80-0x9f (a
# terminal reading the stream as Latin-1/8-bit treats a bare 0x9b as CSI). But a
# 0x80-0x9f byte must be PRESERVED when it is a legitimate continuation byte of a
# multibyte codepoint (em dash, emoji). Distinguishing "orphan C1 byte" from
# "continuation byte" is context-sensitive over the whole sequence (3- and 4-byte
# codepoints have continuation bytes whose immediate predecessor is itself a
# continuation byte), which `tr`/`sed` cannot track. Real UTF-8 parsing is
# required, so the bash path uses a single python3 invocation.
#
# Primary path is python3 (full UTF-8 correctness). A python3-free FALLBACK is
# required: session-start.sh's boot-banner update block has an explicit no-python3
# branch (it still calls scrub_control_chars_oneline on plugin version strings),
# guarded by contract test SSB-5c. The framework's other fallbacks are sed-based
# and the project takes no perl dependency, so the fallback here is `tr`-only.
#
#   - WITH python3 (the normal case, incl. the codex review adapter and
#     workspace-context branch/remote scrubs, which carry real UTF-8): codepoint
#     -aware, multibyte-preserving. See behaviour below.
#   - WITHOUT python3 (degraded fallback): byte-wise `tr -d` over the raw control
#     ranges INCLUDING 0x80-0x9f. This still strips every dangerous control byte
#     (raw C0/C1/0x7f → no ESC/CSI reaches the banner), satisfying the security
#     floor; it does NOT preserve multibyte UTF-8 (the #799 bug persists only in
#     this rare degraded mode). Acceptable because the sole no-python3 caller
#     scrubs short ASCII version strings, and any environment carrying UTF-8
#     author content through the bash functions (codex adapter, git metadata)
#     has python3.
#
# python3 invalid-/non-UTF-8 input policy: input is decoded with
# errors="surrogateescape", so invalid bytes survive as lone surrogates and are
# re-encoded byte-identically — EXCEPT raw C0/C1/0x7f bytes, which are stripped
# whether they arrive as valid codepoints (e.g. c2 9b) or as surrogate-escaped
# orphan bytes (e.g. a bare 0x9b CSI — 8-bit-terminal defense; see SCC/WSC-10).
# Everything else passes through unchanged; the scrub never crashes.
#
# Performance: no per-prompt hot path uses these bash functions. The boot banner
# (once per session) and statusline scrub via their own python3 env-bridge
# heredocs (unchanged, already codepoint-correct). The bash-function callers are
# infrequent git-metadata / review-body scrubs, so one python3 process per call
# is fine.
#
# The python `\x` regex class (codepoints) is the single source of truth; the
# env-bridge consumers and the python primary path below scrub that same codepoint
# set. Their equivalence over a UTF-8 corpus is enforced (not trusted) by
# _smoke-test-contract-scrub-control-chars.sh (SCC-1).

# Canonical class in python-regex form — the single source of truth, env-bridged
# to python consumers (which operate on UTF-8-decoded `str`, so this class
# matches codepoints directly). Single-quoted: literal backslashes.
export ARBO_CTRL_CHAR_CLASS='[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]'

# Surrogate-escape twin of the canonical class: the same control bytes after a
# surrogateescape decode of invalid input land at U+DC00 + byte. Stripping this
# range removes raw orphan C0/C1/0x7f bytes (e.g. a bare 0x9b CSI) while leaving
# valid multibyte continuation bytes — which decoded to real codepoints — intact.
# Derived from ARBO_CTRL_CHAR_CLASS (same offsets, +0xDC00), not a second source.
export ARBO_CTRL_CHAR_CLASS_SURROGATE='[\udc00-\udc08\udc0b\udc0c\udc0e-\udc1f\udc7f-\udc9f]'

# Internal: the python3 codepoint-aware scrub. $1 selects the oneline variant.
_scrub_ctrl_py() {
  ARBO_CTRL_CHAR_CLASS="$ARBO_CTRL_CHAR_CLASS" \
  ARBO_CTRL_CHAR_CLASS_SURROGATE="$ARBO_CTRL_CHAR_CLASS_SURROGATE" \
  ARBO_SCRUB_ONELINE="${1:-}" \
  python3 -c '
import sys, os, re
t = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
t = re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", t)
t = re.sub(os.environ["ARBO_CTRL_CHAR_CLASS_SURROGATE"], "", t)
if os.environ.get("ARBO_SCRUB_ONELINE"):
    t = t.replace("\t", "").replace("\n", "").replace("\r", "")
sys.stdout.buffer.write(t.encode("utf-8", "surrogateescape"))
'
}

# Security scrub: strip control codepoints, preserve \t \n \r. Reads stdin,
# writes stdout. Usage: printf '%s' "$x" | scrub_control_chars
scrub_control_chars() {
  if command -v python3 >/dev/null 2>&1; then
    _scrub_ctrl_py ""
  else
    # Degraded python3-free fallback (byte-wise; does not preserve multibyte UTF-8
    # but strips every dangerous control byte — see header).
    LC_ALL=C tr -d '\000-\010\013\014\016-\037\177-\237'
  fi
}

# Display scrub: the canonical set PLUS \t \n \r, for single-line output.
# Usage: printf '%s' "$x" | scrub_control_chars_oneline
scrub_control_chars_oneline() {
  if command -v python3 >/dev/null 2>&1; then
    _scrub_ctrl_py 1
  else
    LC_ALL=C tr -d '\000-\037\177-\237'
  fi
}
