#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-write-escape-hatch.sh — Contract test for
# docs/contracts/write-escape-hatch.contract.md. Asserts WEH-1..WEH-6 from the
# contract's ## Test surface against scripts/write-escape-hatch.sh.
#
# Fixture pattern: write a fixture design spec with frontmatter + body into a
# mktemp -d, run the producer, assert the rewritten frontmatter. WEH-4 parses
# the rewritten block with the same minimalist `^---\n…---\n` shape the
# downstream frontmatter readers use.
#
# Asserts existing behaviour only — green immediately. Never modifies a script.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE="$SCRIPT_DIR/write-escape-hatch.sh"
[ -f "$WRITE" ] || { echo "FAIL: $WRITE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

make_spec() {
  # $1 = path
  cat > "$1" <<'SPEC'
---
date: 2026-05-30
related-issue: 42
triage: agent-target
---

# Design spec body

Some prose here that must be preserved verbatim.
SPEC
}

# ── WEH-1 / WEH-2: append + sub-key values ────────────────────────────
SPEC1="$FIX/spec1.md"
make_spec "$SPEC1"
bash "$WRITE" "$SPEC1" "design-decision-surfaced" "everything-else:SURVEY" >/dev/null 2>&1
weh1_exit=$?
weh1=$(python3 -c "
import re, sys
text = open('$SPEC1', encoding='utf-8').read()
m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
if not m:
    print('FAIL: frontmatter no longer parses'); sys.exit()
fm = m.group(1)
p = []
if 'escape-hatch:' not in fm: p.append('no escape-hatch: key in frontmatter')
if '\n  trigger: design-decision-surfaced\n' not in fm: p.append('trigger sub-key wrong/missing')
if '\n  redirect-target: everything-else:SURVEY\n' not in fm: p.append('redirect-target sub-key wrong/missing')
# body preserved
if 'Some prose here that must be preserved verbatim.' not in text: p.append('body not preserved')
# starts with ---
if not text.startswith('---\n'): p.append('file no longer starts with ---')
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$weh1_exit" -eq 0 ] && [ "$weh1" = "OK" ]; then
  pass "WEH-1/WEH-2: escape-hatch block appended in frontmatter with trigger+redirect-target, body preserved"
else
  fail_case "WEH-1/WEH-2: append/sub-keys wrong (exit=$weh1_exit)" "$weh1
----- file -----
$(cat "$SPEC1")"
fi

# ── WEH-3: idempotent replace — second call leaves exactly one block ──
bash "$WRITE" "$SPEC1" "second-trigger" "build:RESUME" >/dev/null 2>&1
weh3=$(python3 -c "
import re, sys
text = open('$SPEC1', encoding='utf-8').read()
m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
fm = m.group(1)
count = fm.count('escape-hatch:')
p = []
if count != 1: p.append('escape-hatch: appears %d times (expected 1)' % count)
if '\n  trigger: second-trigger\n' not in fm: p.append('trigger not updated to second-trigger')
if '\n  redirect-target: build:RESUME\n' not in fm: p.append('redirect-target not updated')
if 'design-decision-surfaced' in fm: p.append('stale first-call trigger still present')
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$weh3" = "OK" ]; then
  pass "WEH-3: idempotent replace — exactly one escape-hatch block with the second call's values"
else
  fail_case "WEH-3: idempotent replace failed" "$weh3
----- file -----
$(cat "$SPEC1")"
fi

# ── WEH-4: parseable — nested sub-keys readable via minimalist parse ──
weh4=$(python3 -c "
import re, sys
text = open('$SPEC1', encoding='utf-8').read()
m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
if not m:
    print('FAIL: no frontmatter'); sys.exit()
fm = m.group(1)
# Minimalist parse for the escape-hatch fixture shape: top-level key:, then
# indented sub-keys.
out, cur_key, cur_sub = {}, None, {}
for line in fm.splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    if line.startswith('  ') and cur_key is not None:
        k, v = line.strip().split(':', 1); cur_sub[k.strip()] = v.strip(); continue
    if cur_key is not None and cur_sub:
        out[cur_key] = cur_sub; cur_sub = {}; cur_key = None
    if ':' in line:
        k, v = line.split(':', 1); k, v = k.strip(), v.strip()
        if v: out[k] = v; cur_key = None
        else: cur_key = k; cur_sub = {}
if cur_key is not None and cur_sub: out[cur_key] = cur_sub
eh = out.get('escape-hatch')
p = []
if not isinstance(eh, dict): p.append('escape-hatch not parsed as object: %r' % eh)
else:
    if eh.get('trigger') != 'second-trigger': p.append('trigger=%r' % eh.get('trigger'))
    if eh.get('redirect-target') != 'build:RESUME': p.append('redirect-target=%r' % eh.get('redirect-target'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$weh4" = "OK" ]; then
  pass "WEH-4: rewritten frontmatter parses; escape-hatch.trigger / .redirect-target readable as nested sub-keys"
else
  fail_case "WEH-4: nested parse failed" "$weh4"
fi

# ── WEH-5: no-frontmatter → exit 2, unmodified ────────────────────────
SPEC5="$FIX/nofm.md"
printf '# Just a heading\n\nNo frontmatter here.\n' > "$SPEC5"
before5=$(cat "$SPEC5")
bash "$WRITE" "$SPEC5" "t" "r" >/dev/null 2>&1
weh5_exit=$?
after5=$(cat "$SPEC5")
if [ "$weh5_exit" -eq 2 ] && [ "$before5" = "$after5" ]; then
  pass "WEH-5: no-frontmatter file exits 2 and is left unmodified"
else
  fail_case "WEH-5: expected exit 2 + unmodified (exit=$weh5_exit, changed=$( [ "$before5" = "$after5" ] && echo no || echo yes ))"
fi

# ── WEH-6: arg guards — wrong arg count + missing spec → exit 1 ───────
bash "$WRITE" "$SPEC1" "only-two-args" >/dev/null 2>&1
weh6a=$?
bash "$WRITE" "$FIX/does-not-exist.md" "t" "r" >/dev/null 2>&1
weh6b=$?
if [ "$weh6a" -eq 1 ] && [ "$weh6b" -eq 1 ]; then
  pass "WEH-6: wrong arg count exits 1; non-existent spec exits 1"
else
  fail_case "WEH-6: arg guards wrong (wrong-argc=$weh6a, missing-spec=$weh6b)"
fi

# ── Summary ───────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  echo "All write-escape-hatch contract assertions passed."
  exit 0
else
  echo "Some write-escape-hatch contract assertions failed." >&2
  exit 1
fi
