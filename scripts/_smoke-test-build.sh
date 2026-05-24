#!/usr/bin/env bash
# owner: workflow-unification
# _smoke-test-build.sh — Verify /build's parse/validate/write helpers
# (parse-plan-checkboxes.sh, read-s2-frontmatter.sh, write-escape-hatch.sh).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

PARSE="$REPO_ROOT/scripts/parse-plan-checkboxes.sh"

# ── parse-plan-checkboxes ────────────────────────────────────────────

# Case 1: empty plan → open=0 total=0 skipped=0
f="$ROOT_TMP/empty.md"
: > "$f"
out=$(bash "$PARSE" "$f")
[ "$out" = "open=0 total=0 skipped=0" ] || fail "parse case 1 — empty plan" "got: $out"
ok "parse case 1 — empty plan returns zeros"

# Case 2: all checked → open=0 total=3 skipped=0
cat > "$f" <<'MD'
- [x] one
- [x] two
- [x] three
MD
out=$(bash "$PARSE" "$f")
[ "$out" = "open=0 total=3 skipped=0" ] || fail "parse case 2 — all checked" "got: $out"
ok "parse case 2 — all-checked plan counted"

# Case 3: mixed open/checked → open=2 total=5 skipped=0
cat > "$f" <<'MD'
- [x] done
- [ ] still open
- [x] done2
- [ ] still open 2
- [x] done3
MD
out=$(bash "$PARSE" "$f")
[ "$out" = "open=2 total=5 skipped=0" ] || fail "parse case 3 — mixed" "got: $out"
ok "parse case 3 — mixed open/checked counted"

# Case 4: skip annotation counted as resolved (D4)
cat > "$f" <<'MD'
- [x] (skipped: dependency removed) was: do the thing
- [x] real
- [ ] still open
MD
out=$(bash "$PARSE" "$f")
[ "$out" = "open=1 total=3 skipped=1" ] || fail "parse case 4 — skipped" "got: $out"
ok "parse case 4 — (skipped: …) annotation counted as resolved + tagged"

# Case 5: no checkboxes → zeros
cat > "$f" <<'MD'
# Just a plan with no checkboxes
Some prose.
MD
out=$(bash "$PARSE" "$f")
[ "$out" = "open=0 total=0 skipped=0" ] || fail "parse case 5 — no checkboxes" "got: $out"
ok "parse case 5 — no checkboxes returns zeros"

# ── read-s2-frontmatter ──────────────────────────────────────────────
READ="$REPO_ROOT/scripts/read-s2-frontmatter.sh"

make_spec() {
  # Writes a happy-path design spec to $1. Caller can sed out fields to
  # simulate missing/invalid cases.
  cat > "$1" <<'MD'
---
date: 2026-05-22
topic: example
related-issue: 283
test-tiers:
  unit: yes
  contract: n/a — no shared definitions
  integration: yes
implementation-mode: executing-plans
triage: everything-else
plan: docs/superpowers/plans/2026-05-22-example.md
---

# Example
MD
}

# Case 1: all five fields present → exit 0, prints key=value lines.
f="$ROOT_TMP/spec1.md"; make_spec "$f"
out=$(bash "$READ" "$f")
echo "$out" | grep -q '^related-issue=283$'            || fail "frontmatter case 1 — related-issue line"        "$out"
echo "$out" | grep -q '^implementation-mode=executing-plans$' || fail "frontmatter case 1 — implementation-mode line" "$out"
echo "$out" | grep -q '^triage=everything-else$'       || fail "frontmatter case 1 — triage line"               "$out"
echo "$out" | grep -q '^plan=docs/superpowers/plans/2026-05-22-example.md$' || fail "frontmatter case 1 — plan line" "$out"
echo "$out" | grep -q '^test-tiers.unit=yes$'          || fail "frontmatter case 1 — test-tiers.unit line"      "$out"
ok "frontmatter case 1 — all five required fields present"

# Cases 2.X: each required top-level field missing → exit 2, error names the field.
for field in related-issue implementation-mode triage plan; do
  f="$ROOT_TMP/missing-$field.md"
  make_spec "$f"
  # Delete the line whose key matches exactly (avoid matching test-tiers.*).
  python3 -c "
import re, sys
p = sys.argv[1]; field = sys.argv[2]
t = open(p).read()
t = re.sub(rf'^{re.escape(field)}:.*\n', '', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f" "$field"
  if out=$(bash "$READ" "$f" 2>&1); then
    fail "frontmatter case 2.$field — should fail when $field missing" "$out"
  fi
  echo "$out" | grep -qi "$field" || fail "frontmatter case 2.$field — error should name $field" "$out"
  ok "frontmatter case 2.$field — missing $field rejected with named error"
done

# Case 2.test-tiers: top-level test-tiers key (and its sub-keys) removed.
f="$ROOT_TMP/missing-test-tiers.md"; make_spec "$f"
python3 -c "
import re, sys
p = sys.argv[1]
t = open(p).read()
# Drop the test-tiers: line AND the indented sub-lines that follow.
t = re.sub(r'^test-tiers:\n(?:  [^\n]*\n)+', '', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 2.test-tiers — should fail when test-tiers missing" "$out"
fi
echo "$out" | grep -qi "test-tiers" || fail "frontmatter case 2.test-tiers — error should name test-tiers" "$out"
ok "frontmatter case 2.test-tiers — missing test-tiers rejected"

# Case 7: plan: null is accepted (pure-TDD mode per D3).
f="$ROOT_TMP/spec-null-plan.md"; make_spec "$f"
python3 -c "
import sys
p = sys.argv[1]; t = open(p).read()
import re; t = re.sub(r'^plan:.*$', 'plan: null', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
out=$(bash "$READ" "$f")
echo "$out" | grep -q '^plan=null$' || fail "frontmatter case 7 — plan: null should be accepted" "$out"
ok "frontmatter case 7 — plan: null accepted (pure-TDD mode)"

# Case 8: invalid implementation-mode enum value rejected.
f="$ROOT_TMP/bad-mode.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'^implementation-mode:.*$', 'implementation-mode: vibes', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 8 — invalid mode should fail" "$out"
fi
echo "$out" | grep -qi "implementation-mode" || fail "frontmatter case 8 — error should name field" "$out"
ok "frontmatter case 8 — invalid implementation-mode enum rejected"

# Case 9: test-tiers must be an object — scalar value rejected.
f="$ROOT_TMP/scalar-tiers.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
# Replace the multi-line test-tiers: block with a scalar value.
t = re.sub(r'^test-tiers:\n(?:  [^\n]*\n)+', 'test-tiers: all\n', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 9 — scalar test-tiers should fail" "$out"
fi
echo "$out" | grep -qi "test-tiers" || fail "frontmatter case 9 — error should name test-tiers" "$out"
ok "frontmatter case 9 — scalar test-tiers rejected (must be an object)"

# Case 10: test-tiers must have at least one of unit/contract/integration sub-keys.
f="$ROOT_TMP/empty-tiers.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
# Replace sub-keys with a single unrelated sub-key.
t = re.sub(r'^test-tiers:\n(?:  [^\n]*\n)+', 'test-tiers:\n  other: yes\n', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 10 — empty/unrecognized test-tiers should fail" "$out"
fi
echo "$out" | grep -qi "test-tiers" || fail "frontmatter case 10 — error should name test-tiers" "$out"
ok "frontmatter case 10 — test-tiers without unit/contract/integration sub-keys rejected"

# Case 11: related-issue must be an integer.
f="$ROOT_TMP/string-issue.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'^related-issue:.*$', 'related-issue: not-a-number', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 11 — non-integer related-issue should fail" "$out"
fi
echo "$out" | grep -qi "related-issue" || fail "frontmatter case 11 — error should name related-issue" "$out"
ok "frontmatter case 11 — non-integer related-issue rejected"

# Case 12: plan must be null or a relative path — absolute path rejected.
f="$ROOT_TMP/abs-plan.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'^plan:.*$', 'plan: /etc/passwd', t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 12 — absolute plan path should fail" "$out"
fi
echo "$out" | grep -qi "plan" || fail "frontmatter case 12 — error should name plan" "$out"
ok "frontmatter case 12 — absolute plan path rejected (must be relative or null)"

# Case 13: plan: empty string rejected (per Copilot — "non-empty relative path").
f="$ROOT_TMP/empty-plan.md"; make_spec "$f"
python3 -c "
import sys, re
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'^plan:.*$', \"plan: ''\", t, flags=re.MULTILINE)
open(p, 'w').write(t)
" "$f"
if out=$(bash "$READ" "$f" 2>&1); then
  fail "frontmatter case 13 — empty plan value should fail" "$out"
fi
echo "$out" | grep -qi "plan" || fail "frontmatter case 13 — error should name plan" "$out"
ok "frontmatter case 13 — empty plan value rejected"

# ── write-escape-hatch ───────────────────────────────────────────────
WRITE="$REPO_ROOT/scripts/write-escape-hatch.sh"

# Case 1: append to a clean spec.
f="$ROOT_TMP/spec-clean.md"; make_spec "$f"
bash "$WRITE" "$f" "tdd-tier-discovery" "/design"
grep -q "^escape-hatch:" "$f"          || fail "escape-hatch case 1 — block should be appended" "$(cat "$f")"
grep -q "trigger: tdd-tier-discovery" "$f"   || fail "escape-hatch case 1 — trigger should be named" "$(cat "$f")"
grep -q "redirect-target: /design" "$f" || fail "escape-hatch case 1 — redirect-target named" "$(cat "$f")"
ok "escape-hatch case 1 — clean append"

# Case 2: idempotent — appending twice still leaves one block.
bash "$WRITE" "$f" "tdd-tier-discovery" "/design"
n=$(grep -c "^escape-hatch:" "$f" || true)
[ "$n" = "1" ] || fail "escape-hatch case 2 — should be idempotent (got $n blocks)" "$(cat "$f")"
ok "escape-hatch case 2 — idempotent (one block after two calls)"

# Case 3: second call with different values overwrites trigger + redirect.
bash "$WRITE" "$f" "design-rethink" "/architect"
grep -q "trigger: design-rethink" "$f"     || fail "escape-hatch case 3 — trigger should be updated" "$(cat "$f")"
grep -q "redirect-target: /architect" "$f" || fail "escape-hatch case 3 — redirect-target should be updated" "$(cat "$f")"
grep -q "trigger: tdd-tier-discovery" "$f" && fail "escape-hatch case 3 — old trigger should be gone" "$(cat "$f")"
ok "escape-hatch case 3 — second call updates trigger + redirect in place"

# Case 4: missing args rejected.
if out=$(bash "$WRITE" "$f" 2>&1); then
  fail "escape-hatch case 4 — missing args should fail" "$out"
fi
ok "escape-hatch case 4 — missing args rejected"

echo
echo "build helper smoke tests passed."
exit 0
