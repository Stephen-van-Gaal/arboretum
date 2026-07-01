#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-write-design-brief.sh — Contract test for
# docs/contracts/write-design-brief.contract.md. Asserts WDB-1..WDB-23.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE="$SCRIPT_DIR/write-design-brief.sh"
[ -f "$WRITE" ] || { echo "FAIL: $WRITE not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── WDB-1 / WDB-2: happy path, full payload ────────────────────────────
FIX1=$(mktemp -d)
out1=$(cd "$FIX1" && cat <<'JSON' | bash "$WRITE" 12345
{
  "branch1-mode": "brainstorm",
  "requirements": "Convert /design to split dispatch mode.",
  "survey-findings": [{"artifact": "conductor-workflow.spec.md", "why": "defines dispatch-mode vocabulary"}],
  "decisions": [{"decision": "Use a structured brief", "alternatives-considered": "Transcript summary", "rationale": "Typed fields are validatable"}],
  "customer-experience-notes": "No visible change to the normal path."
}
JSON
)
BRIEF1="$FIX1/.arboretum/design-briefs/12345.md"
if [ -f "$BRIEF1" ]; then
  pass "WDB-1: happy path writes the brief"
else
  fail_case "WDB-1: brief not written"
fi
if [ "$out1" = ".arboretum/design-briefs/12345.md" ]; then
  pass "WDB-1: prints the written brief path to stdout"
else
  fail_case "WDB-1: unexpected stdout" "$out1"
fi
if grep -q "related-issue: 12345" "$BRIEF1" 2>/dev/null && grep -q "branch1-mode: brainstorm" "$BRIEF1" 2>/dev/null; then
  pass "WDB-2: frontmatter carries related-issue and branch1-mode"
else
  fail_case "WDB-2: frontmatter missing expected fields" "$(cat "$BRIEF1" 2>/dev/null)"
fi
rm -rf "$FIX1"

# ── WDB-3: minimal payload omits optional sections ─────────────────────
FIX3=$(mktemp -d)
( cd "$FIX3" && printf '%s' '{"branch1-mode":"none","requirements":"Trivial change."}' | bash "$WRITE" 222 >/dev/null )
BRIEF3="$FIX3/.arboretum/design-briefs/222.md"
if grep -q "## Requirements" "$BRIEF3" 2>/dev/null \
   && ! grep -q "## Survey Findings" "$BRIEF3" 2>/dev/null \
   && ! grep -q "## Decisions" "$BRIEF3" 2>/dev/null \
   && ! grep -q "## Customer Experience Notes" "$BRIEF3" 2>/dev/null; then
  pass "WDB-3: minimal payload omits all three optional sections"
else
  fail_case "WDB-3: optional sections present when they shouldn't be" "$(cat "$BRIEF3" 2>/dev/null)"
fi
rm -rf "$FIX3"

# ── WDB-4: decisions table has one row per entry ───────────────────────
FIX4=$(mktemp -d)
( cd "$FIX4" && cat <<'JSON' | bash "$WRITE" 333 >/dev/null
{
  "branch1-mode": "investigate",
  "requirements": "Fix the bug.",
  "decisions": [
    {"decision": "D1", "alternatives-considered": "A1", "rationale": "R1"},
    {"decision": "D2", "alternatives-considered": "A2", "rationale": "R2"}
  ]
}
JSON
)
BRIEF4="$FIX4/.arboretum/design-briefs/333.md"
rows=$(grep -c "^| D[12] " "$BRIEF4" 2>/dev/null || echo 0)
if [ "$rows" = "2" ]; then
  pass "WDB-4: decisions table has one row per entry"
else
  fail_case "WDB-4: expected 2 decision rows, got $rows" "$(cat "$BRIEF4" 2>/dev/null)"
fi
rm -rf "$FIX4"

# ── WDB-5: invalid issue values ─────────────────────────────────────────
wdb5_fail=0
for bad in 0 01 abc ""; do
  FIX5=$(mktemp -d)
  ( cd "$FIX5" && printf '%s' '{"branch1-mode":"none","requirements":"x"}' | bash "$WRITE" "$bad" >/dev/null 2>&1 )
  ec=$?
  present=$(find "$FIX5/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
  if [ "$ec" -ne 0 ] && [ -z "$present" ]; then
    :
  else
    wdb5_fail=1
    fail_case "WDB-5: invalid issue '$bad' should exit 1 + write nothing (exit=$ec, brief=$present)"
  fi
  rm -rf "$FIX5"
done
[ "$wdb5_fail" -eq 0 ] && pass "WDB-5: invalid issues (0, 01, abc, empty) exit 1 and write no brief"

# ── WDB-6: invalid branch1-mode ─────────────────────────────────────────
FIX6=$(mktemp -d)
( cd "$FIX6" && printf '%s' '{"branch1-mode":"bogus","requirements":"x"}' | bash "$WRITE" 444 >/dev/null 2>&1 )
ec6=$?
present6=$(find "$FIX6/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec6" -ne 0 ] && [ -z "$present6" ]; then
  pass "WDB-6: invalid branch1-mode exits 1 and writes no brief"
else
  fail_case "WDB-6: invalid branch1-mode should exit 1 + write nothing (exit=$ec6, brief=$present6)"
fi
rm -rf "$FIX6"

# ── WDB-7: missing requirements ─────────────────────────────────────────
FIX7=$(mktemp -d)
( cd "$FIX7" && printf '%s' '{"branch1-mode":"none"}' | bash "$WRITE" 555 >/dev/null 2>&1 )
ec7=$?
present7=$(find "$FIX7/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec7" -ne 0 ] && [ -z "$present7" ]; then
  pass "WDB-7: missing requirements exits 1 and writes no brief"
else
  fail_case "WDB-7: missing requirements should exit 1 + write nothing (exit=$ec7, brief=$present7)"
fi
rm -rf "$FIX7"

# ── WDB-8: malformed JSON ────────────────────────────────────────────────
FIX8=$(mktemp -d)
( cd "$FIX8" && printf 'not json' | bash "$WRITE" 666 >/dev/null 2>&1 )
ec8=$?
present8=$(find "$FIX8/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec8" -ne 0 ] && [ -z "$present8" ]; then
  pass "WDB-8: malformed JSON exits 1 and writes no brief"
else
  fail_case "WDB-8: malformed JSON should exit 1 + write nothing (exit=$ec8, brief=$present8)"
fi
rm -rf "$FIX8"

# ── WDB-9: control characters stripped from requirements (scrub-at-source) ──
FIX9=$(mktemp -d)
PAYLOAD9=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"before\x1bafter"}))')
( cd "$FIX9" && printf '%s' "$PAYLOAD9" | bash "$WRITE" 777 >/dev/null )
BRIEF9="$FIX9/.arboretum/design-briefs/777.md"
if grep -q "beforeafter" "$BRIEF9" 2>/dev/null; then
  pass "WDB-9: control characters stripped from requirements"
else
  fail_case "WDB-9: control character not stripped" "$(cat "$BRIEF9" 2>/dev/null | cat -A | head -5)"
fi
rm -rf "$FIX9"

# ── WDB-10: '|' escaped and newlines collapsed in decision table cells ──────
FIX10=$(mktemp -d)
( cd "$FIX10" && cat <<'JSON' | bash "$WRITE" 888 >/dev/null
{"branch1-mode":"none","requirements":"x",
 "decisions":[{"decision":"a | b\nc","alternatives-considered":"n/a","rationale":"n/a"}]}
JSON
)
BRIEF10="$FIX10/.arboretum/design-briefs/888.md"
if grep -q '| a \\| b c |' "$BRIEF10" 2>/dev/null; then
  pass "WDB-10: '|' escaped and embedded newline collapsed in decision cell"
else
  fail_case "WDB-10: table cell not properly escaped" "$(cat "$BRIEF10" 2>/dev/null)"
fi
rm -rf "$FIX10"

# ── WDB-11: non-object survey-findings element exits 1 cleanly (no traceback) ─
FIX11=$(mktemp -d)
out11=$( cd "$FIX11" && printf '%s' '{"branch1-mode":"none","requirements":"x","survey-findings":["bad"]}' | bash "$WRITE" 111 2>&1 )
ec11=$?
present11=$(find "$FIX11/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec11" -ne 0 ] && [ -z "$present11" ] && ! printf '%s' "$out11" | grep -q "Traceback"; then
  pass "WDB-11: non-object survey-findings element exits 1 with a clean diagnostic, no traceback"
else
  fail_case "WDB-11: expected clean exit 1, got exit=$ec11" "$out11"
fi
rm -rf "$FIX11"

# ── WDB-12: non-object decisions element exits 1 cleanly (no traceback) ──────
FIX12=$(mktemp -d)
out12=$( cd "$FIX12" && printf '%s' '{"branch1-mode":"none","requirements":"x","decisions":["bad"]}' | bash "$WRITE" 112 2>&1 )
ec12=$?
present12=$(find "$FIX12/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec12" -ne 0 ] && [ -z "$present12" ] && ! printf '%s' "$out12" | grep -q "Traceback"; then
  pass "WDB-12: non-object decisions element exits 1 with a clean diagnostic, no traceback"
else
  fail_case "WDB-12: expected clean exit 1, got exit=$ec12" "$out12"
fi
rm -rf "$FIX12"

# ── WDB-13: non-string customer-experience-notes exits 1 cleanly ────────────
FIX13=$(mktemp -d)
out13=$( cd "$FIX13" && printf '%s' '{"branch1-mode":"none","requirements":"x","customer-experience-notes":42}' | bash "$WRITE" 113 2>&1 )
ec13=$?
present13=$(find "$FIX13/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec13" -ne 0 ] && [ -z "$present13" ] && ! printf '%s' "$out13" | grep -q "Traceback"; then
  pass "WDB-13: non-string customer-experience-notes exits 1 with a clean diagnostic, no traceback"
else
  fail_case "WDB-13: expected clean exit 1, got exit=$ec13" "$out13"
fi
rm -rf "$FIX13"

# ── WDB-14: kind:shaping renders into frontmatter; omitted kind does not ────
FIX14=$(mktemp -d)
( cd "$FIX14" && printf '%s' '{"branch1-mode":"none","requirements":"x","kind":"shaping"}' | bash "$WRITE" 114 >/dev/null )
BRIEF14="$FIX14/.arboretum/design-briefs/114.md"
if grep -qx "kind: shaping" "$BRIEF14" 2>/dev/null; then
  pass "WDB-14: kind:shaping renders into the design-brief frontmatter"
else
  fail_case "WDB-14: kind: shaping missing from frontmatter" "$(cat "$BRIEF14" 2>/dev/null)"
fi
rm -rf "$FIX14"

FIX15=$(mktemp -d)
( cd "$FIX15" && printf '%s' '{"branch1-mode":"none","requirements":"x"}' | bash "$WRITE" 115 >/dev/null )
BRIEF15="$FIX15/.arboretum/design-briefs/115.md"
if ! grep -q "^kind:" "$BRIEF15" 2>/dev/null; then
  pass "WDB-15: omitted kind emits no kind: line (default buildable)"
else
  fail_case "WDB-15: kind: line present when omitted" "$(cat "$BRIEF15" 2>/dev/null)"
fi
rm -rf "$FIX15"

# ── WDB-16: invalid kind value exits 1 cleanly ───────────────────────────────
FIX16=$(mktemp -d)
( cd "$FIX16" && printf '%s' '{"branch1-mode":"none","requirements":"x","kind":"bogus"}' | bash "$WRITE" 116 >/dev/null 2>&1 )
ec16=$?
present16=$(find "$FIX16/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec16" -ne 0 ] && [ -z "$present16" ]; then
  pass "WDB-16: invalid kind value exits 1 and writes no brief"
else
  fail_case "WDB-16: invalid kind should exit 1 + write nothing (exit=$ec16, brief=$present16)"
fi
rm -rf "$FIX16"

# ── WDB-17: '\r' collapsed to a space in decision table cells ───────────────
FIX17=$(mktemp -d)
PAYLOAD17=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"x","decisions":[{"decision":"a\rb","alternatives-considered":"n/a","rationale":"n/a"}]}))')
( cd "$FIX17" && printf '%s' "$PAYLOAD17" | bash "$WRITE" 117 >/dev/null )
BRIEF17="$FIX17/.arboretum/design-briefs/117.md"
if grep -q '| a b | n/a | n/a |' "$BRIEF17" 2>/dev/null; then
  pass "WDB-17: embedded carriage return collapsed in decision cell"
else
  fail_case "WDB-17: '\r' not collapsed in table cell" "$(cat "$BRIEF17" 2>/dev/null | cat -A)"
fi
rm -rf "$FIX17"

# ── WDB-18: decisions:false (non-array, falsy) exits 1 cleanly ──────────────
FIX18=$(mktemp -d)
out18=$( cd "$FIX18" && printf '%s' '{"branch1-mode":"none","requirements":"x","decisions":false}' | bash "$WRITE" 118 2>&1 )
ec18=$?
present18=$(find "$FIX18/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec18" -ne 0 ] && [ -z "$present18" ] && printf '%s' "$out18" | grep -qi "decisions"; then
  pass "WDB-18: decisions:false exits 1 with a clean diagnostic, writes nothing"
else
  fail_case "WDB-18: expected clean exit 1 diagnosing decisions, got exit=$ec18" "$out18"
fi
rm -rf "$FIX18"

# ── WDB-19: requirements is a single ESC control char exits 1 cleanly ───────
FIX19=$(mktemp -d)
PAYLOAD19=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"\x1b"}))')
out19=$( cd "$FIX19" && printf '%s' "$PAYLOAD19" | bash "$WRITE" 119 2>&1 )
ec19=$?
present19=$(find "$FIX19/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec19" -ne 0 ] && [ -z "$present19" ] && printf '%s' "$out19" | grep -qi "scrub"; then
  pass "WDB-19: control-char-only requirements exits 1 with an after-scrubbing diagnostic, writes nothing"
else
  fail_case "WDB-19: expected clean exit 1 diagnosing post-scrub emptiness, got exit=$ec19" "$out19"
fi
rm -rf "$FIX19"

# ── WDB-20: bare JSON array as payload root exits 1 cleanly (no traceback) ──
FIX20=$(mktemp -d)
out20=$( cd "$FIX20" && printf '%s' '["not", "an", "object"]' | bash "$WRITE" 120 2>&1 )
ec20=$?
present20=$(find "$FIX20/.arboretum/design-briefs" -name '*.md' 2>/dev/null | head -1)
if [ "$ec20" -ne 0 ] && [ -z "$present20" ] && ! printf '%s' "$out20" | grep -q "Traceback"; then
  pass "WDB-20: non-object JSON root exits 1 with a clean diagnostic, no traceback"
else
  fail_case "WDB-20: expected clean exit 1, got exit=$ec20" "$out20"
fi
rm -rf "$FIX20"

# ── WDB-21: non-string decision field renders empty, doesn't crash ──────────
FIX21=$(mktemp -d)
PAYLOAD21=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"x","decisions":[{"decision":["a","list"],"alternatives-considered":"x","rationale":"y"}]}))')
out21=$( cd "$FIX21" && printf '%s' "$PAYLOAD21" | bash "$WRITE" 121 2>&1 )
ec21=$?
BRIEF21="$FIX21/.arboretum/design-briefs/121.md"
if [ "$ec21" -eq 0 ] && grep -q '|  | x | y |' "$BRIEF21" 2>/dev/null; then
  pass "WDB-21: non-string decision field renders as empty table cell, doesn't crash"
else
  fail_case "WDB-21: expected exit 0 with an empty decision cell, got exit=$ec21" "$out21"
fi
rm -rf "$FIX21"

# ── WDB-22: non-string survey-finding artifact renders empty, doesn't crash ─
FIX22=$(mktemp -d)
PAYLOAD22=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"x","survey-findings":[{"artifact":42,"why":"test"}]}))')
out22=$( cd "$FIX22" && printf '%s' "$PAYLOAD22" | bash "$WRITE" 122 2>&1 )
ec22=$?
BRIEF22="$FIX22/.arboretum/design-briefs/122.md"
if [ "$ec22" -eq 0 ] && grep -q '^- \*\*\*\* — test$' "$BRIEF22" 2>/dev/null; then
  pass "WDB-22: non-string survey-finding artifact renders as empty bullet lead-in, doesn't crash"
else
  fail_case "WDB-22: expected exit 0 with an empty artifact bullet, got exit=$ec22" "$out22"
fi
rm -rf "$FIX22"

# ── WDB-23: embedded newline in survey-finding 'why' can't inject a heading ──
FIX23=$(mktemp -d)
PAYLOAD23=$(python3 -c 'import json; print(json.dumps({"branch1-mode":"none","requirements":"x","survey-findings":[{"artifact":"a","why":"before\n## Fake Heading\nafter"}]}))')
out23=$( cd "$FIX23" && printf '%s' "$PAYLOAD23" | bash "$WRITE" 123 2>&1 )
ec23=$?
BRIEF23="$FIX23/.arboretum/design-briefs/123.md"
if [ "$ec23" -eq 0 ] && ! grep -qx "## Fake Heading" "$BRIEF23" 2>/dev/null \
   && grep -q "before ## Fake Heading after" "$BRIEF23" 2>/dev/null; then
  pass "WDB-23: embedded newline in survey-finding 'why' is collapsed, no injected heading line"
else
  fail_case "WDB-23: expected the fake heading collapsed inline, not on its own line, got exit=$ec23" "$out23"
fi
rm -rf "$FIX23"

if [ "$fail" -eq 0 ]; then
  echo "All write-design-brief assertions passed."
  exit 0
else
  echo "Some write-design-brief assertions failed." >&2
  exit 1
fi
