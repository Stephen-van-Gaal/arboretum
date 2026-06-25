#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-write-agent-brief.sh — Contract test for
# docs/contracts/write-agent-brief.contract.md. Asserts WAB-1..WAB-6 from the
# contract's ## Test surface against scripts/write-agent-brief.sh.
#
# Fixture pattern: write-agent-brief.sh writes .arboretum/agent-briefs/<issue>.md
# RELATIVE to the CWD, so each case runs inside a mktemp -d fixture dir. WAB-3
# additionally feeds the produced brief into scripts/read-s2-frontmatter.sh to
# prove the round trip (brief is a valid S2 input by construction).
#
# Asserts existing behaviour only — green immediately. Never modifies a script.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE="$SCRIPT_DIR/write-agent-brief.sh"
READ_S2="$SCRIPT_DIR/read-s2-frontmatter.sh"
[ -f "$WRITE" ] || { echo "FAIL: $WRITE not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── WAB-1 / WAB-2 / WAB-3: happy path + schema + round trip ───────────
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
out_path=$( cd "$FIX" && printf '%s\n' "Rename foo to bar in baz.sh" | bash "$WRITE" 12345 )
wab1_exit=$?
BRIEF="$FIX/.arboretum/agent-briefs/12345.md"
if [ "$wab1_exit" -eq 0 ] && [ -f "$BRIEF" ]; then
  pass "WAB-1: write-agent-brief.sh 12345 writes the brief and exits 0"
else
  fail_case "WAB-1: exit=$wab1_exit brief=$( [ -f "$BRIEF" ] && echo yes || echo no )"
fi
# stdout is the brief path (relative to the cd'd fixture)
if [ "$out_path" = ".arboretum/agent-briefs/12345.md" ]; then
  pass "WAB-1: prints the written brief path to stdout"
else
  fail_case "WAB-1: stdout path unexpected" "$out_path"
fi

# WAB-2: frontmatter schema fields
wab2=$(python3 -c "
import re, sys
text = open('$BRIEF', encoding='utf-8').read()
m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
if not m:
    print('FAIL: no frontmatter'); sys.exit()
fm = m.group(1)
p = []
if 'related-issue: 12345' not in fm: p.append('related-issue')
if 'triage: agent-target' not in fm: p.append('triage')
if 'implementation-mode: direct' not in fm: p.append('implementation-mode')
if 'plan: null' not in fm: p.append('plan:null')
if 'test-tiers:' not in fm: p.append('test-tiers')
for sub in ('unit:','contract:','integration:'):
    if sub not in fm: p.append('test-tiers.'+sub)
print('OK' if not p else 'missing: '+', '.join(p))
" 2>&1)
if [ "$wab2" = "OK" ]; then
  pass "WAB-2: frontmatter carries fixed S2 values + test-tiers object with all sub-keys"
else
  fail_case "WAB-2: frontmatter schema incomplete" "$wab2"
fi

# WAB-3: round trip through read-s2-frontmatter.sh
if [ -f "$READ_S2" ]; then
  s2_out=$(bash "$READ_S2" "$BRIEF" 2>&1)
  s2_exit=$?
  if [ "$s2_exit" -eq 0 ] \
     && echo "$s2_out" | grep -qx "related-issue=12345" \
     && echo "$s2_out" | grep -qx "triage=agent-target" \
     && echo "$s2_out" | grep -qx "implementation-mode=direct" \
     && echo "$s2_out" | grep -qx "plan=null"; then
    pass "WAB-3: round trip — read-s2-frontmatter.sh accepts the brief (exit 0) with expected fields"
  else
    fail_case "WAB-3: read-s2-frontmatter rejected the brief or fields wrong (exit=$s2_exit)" "$s2_out"
  fi
else
  echo "INFO: WAB-3: read-s2-frontmatter.sh not found — skipping round-trip assertion"
fi

# ── WAB-4: literal task statement — no shell expansion ────────────────
FIX4=$(mktemp -d)
SENTINEL="$FIX4/pwned"
( cd "$FIX4" && printf '%s\n' "Do the thing \$(touch $SENTINEL) and \`touch $SENTINEL\`" | bash "$WRITE" 222 ) >/dev/null 2>&1 || true
BRIEF4="$FIX4/.arboretum/agent-briefs/222.md"
if [ -f "$SENTINEL" ]; then
  fail_case "WAB-4: task statement was shell-expanded — sentinel file created"
elif grep -qF '$(touch' "$BRIEF4" 2>/dev/null; then
  pass "WAB-4: task statement written verbatim, no shell expansion (sentinel not created)"
else
  fail_case "WAB-4: literal task statement not found in brief" "$(cat "$BRIEF4" 2>/dev/null)"
fi
rm -rf "$FIX4"

# ── WAB-5: invalid issue values → exit 1, no brief ────────────────────
wab5_fail=0
for bad in 0 01 abc ""; do
  FIX5=$(mktemp -d)
  ( cd "$FIX5" && printf '%s\n' "task" | bash "$WRITE" "$bad" >/dev/null 2>&1 )
  ec=$?
  # Any brief written under agent-briefs is a failure.
  briefs_present=$(find "$FIX5/.arboretum/agent-briefs" -name '*.md' 2>/dev/null | head -1)
  if [ "$ec" -ne 0 ] && [ -z "$briefs_present" ]; then
    : # good
  else
    wab5_fail=1
    fail_case "WAB-5: invalid issue '$bad' should exit 1 + write nothing (exit=$ec, brief=$briefs_present)"
  fi
  rm -rf "$FIX5"
done
[ "$wab5_fail" -eq 0 ] && pass "WAB-5: invalid issues (0, 01, abc, empty) exit 1 and write no brief"

# ── WAB-6: empty stdin → exit 1, no brief ─────────────────────────────
FIX6=$(mktemp -d)
( cd "$FIX6" && printf '' | bash "$WRITE" 333 >/dev/null 2>&1 )
ec6=$?
brief6=$(find "$FIX6/.arboretum/agent-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec6" -ne 0 ] && [ -z "$brief6" ]; then
  pass "WAB-6: empty stdin exits 1 and writes no brief"
else
  fail_case "WAB-6: empty stdin should exit 1 + write nothing (exit=$ec6, brief=$brief6)"
fi
rm -rf "$FIX6"

# ── Summary ───────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  echo "All write-agent-brief contract assertions passed."
  exit 0
else
  echo "Some write-agent-brief contract assertions failed." >&2
  exit 1
fi
