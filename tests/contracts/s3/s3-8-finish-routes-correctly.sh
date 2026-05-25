#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-8
# pipeline-version: v2
#
# Asserts: /finish reads the most recent `/build exited` journey-log
# entry's `exit-status:` value and routes — `success` → continue
# ship tail; `escape-hatch` → return to /design.
#
# Structural static analysis: locate the routing block in /finish
# skill text, split into paragraphs, then check each paragraph's
# pairing independently. Paragraph-aware parsing avoids the
# adjacent-branch false-failures the round-4 P1 #2 review flagged
# in the flat 4-line-lookahead approach.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

FINISH="$ROOT/skills/finish/SKILL.md"

if [ ! -f "$FINISH" ]; then
  echo "FAIL: S3-8 — skills/finish/SKILL.md not found" >&2
  exit 1
fi

# Locate the routing block — a line that contains BOTH "exit-status:"
# and a Routing-like heading/keyword within 30 lines. The 30-line
# proximity ensures they're in the same semantic block.
routing_line=$(awk '
  /exit-status:/ { in_section = NR }
  in_section && NR - in_section <= 30 && /[Rr]outing/ { print NR; exit }
' "$FINISH")

if [ -z "$routing_line" ]; then
  echo "FAIL: S3-8 — /finish skill lacks a routing block (need 'exit-status:' and 'Routing' within 30 lines)" >&2
  exit 1
fi

# Extract a 30-line window around the routing block (10 lines before,
# 20 after). Sufficient to capture both branches as separate
# paragraphs in any reasonable markdown layout.
start=$((routing_line - 10))
[ "$start" -lt 1 ] && start=1
end=$((routing_line + 20))
window=$(sed -n "${start},${end}p" "$FINISH")

# Split the window into paragraphs (blank-line separated). For each
# paragraph that mentions 'success' (and is NOT also escape-hatch's
# paragraph): assert continuation indicator + forbid /design.
# Same logic inverted for 'escape-hatch'.
# python3 does the paragraph-aware checking cleanly — much less brittle
# than nested awk/sed in bash.
python3_out=$(WINDOW_TEXT="$window" python3 <<'PY'
# Quoted heredoc (<<'PY') so shell doesn't interpolate into the Python
# body — eliminates the accidental-string-termination risks Codex P2
# flagged on the prior unquoted form. The window contents arrive via
# an env var (not a pipe) to avoid the python3-stdin-vs-heredoc
# collision (`python3 -` reads the SCRIPT from stdin, conflicting
# with a piped data payload).
import os
import re
import sys

window = os.environ['WINDOW_TEXT']

# Split on blank lines (with optional whitespace).
paragraphs = [p for p in re.split(r"\n\s*\n", window) if p.strip()]

continuation_re = re.compile(r"continue|ship|proceed", re.IGNORECASE)
design_re = re.compile(r"/design")

errs = []
saw_success_para = False
saw_escape_para = False

for p in paragraphs:
    has_success = bool(re.search(r"\bsuccess\b", p))
    has_escape = bool(re.search(r"escape-hatch", p))
    if has_success and not has_escape:
        saw_success_para = True
        if not continuation_re.search(p):
            errs.append("success-branch paragraph missing continuation indicator (continue|ship|proceed)")
        if design_re.search(p):
            errs.append("success-branch paragraph contains '/design' (inverted routing?)")
    elif has_escape and not has_success:
        saw_escape_para = True
        if not design_re.search(p):
            errs.append("escape-hatch-branch paragraph missing '/design' target")
        if continuation_re.search(p):
            errs.append("escape-hatch-branch paragraph contains continuation indicator (inverted routing?)")
    # paragraphs mentioning both are skipped — they're prose summary,
    # not branch implementations. The per-branch paragraphs carry the
    # routing claim.

if not saw_success_para:
    errs.append("no paragraph names the 'success' branch in isolation")
if not saw_escape_para:
    errs.append("no paragraph names the 'escape-hatch' branch in isolation")

for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PY
)
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "FAIL: S3-8 — /finish skill routing block is incomplete or inverted:" >&2
  echo "$python3_out" | sed 's/^/  - /' >&2
  exit 1
fi

pass "S3-8"
