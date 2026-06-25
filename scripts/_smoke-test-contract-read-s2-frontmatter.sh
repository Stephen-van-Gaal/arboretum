#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-read-s2-frontmatter.sh — Contract test for
# docs/contracts/read-s2-frontmatter.contract.md. Asserts RS2-1..RS2-8
# against scripts/read-s2-frontmatter.sh using mktemp design-spec
# fixtures. Picked up automatically by ci-checks.sh's
# === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/read-s2-frontmatter.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

SPEC="$FIX/spec.md"

# A fully-valid S2 frontmatter block (used by RS2-1, RS2-2, RS2-7, RS2-8).
write_valid() {
  cat > "$SPEC" <<'EOF'
---
related-issue: 303
test-tiers:
  unit: required
  contract: N/A
implementation-mode: direct
triage: agent-target
plan: 'docs/plans/foo.md'
---
# body
EOF
}

# RS2-1 / RS2-2 — all valid → exit 0, keys present, test-tiers flattened
write_valid
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 0 ] \
   && printf '%s\n' "$out" | grep -qx 'related-issue=303' \
   && printf '%s\n' "$out" | grep -qx 'implementation-mode=direct' \
   && printf '%s\n' "$out" | grep -qx 'triage=agent-target' \
   && printf '%s\n' "$out" | grep -q '^plan='; then
  pass RS2-1
else
  fail_case RS2-1 "rc=$rc out=$out err=$(cat "$FIX/.err")"
fi
if printf '%s\n' "$out" | grep -qx 'test-tiers.unit=required' \
   && ! printf '%s\n' "$out" | grep -qx 'test-tiers='; then
  pass RS2-2
else
  fail_case RS2-2 "out=$out"
fi

# RS2-3 — missing required field (triage) → exit 2, no stdout
cat > "$SPEC" <<'EOF'
---
related-issue: 303
test-tiers:
  unit: required
implementation-mode: direct
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && [ -s "$FIX/.err" ] && pass RS2-3 || fail_case RS2-3 "rc=$rc out=$out"

# RS2-4 — out-of-enum implementation-mode → exit 2
cat > "$SPEC" <<'EOF'
---
related-issue: 303
test-tiers:
  unit: required
implementation-mode: yolo
triage: agent-target
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass RS2-4 || fail_case RS2-4 "rc=$rc out=$out"

# RS2-5 — scalar test-tiers → exit 2
cat > "$SPEC" <<'EOF'
---
related-issue: 303
test-tiers: required
implementation-mode: direct
triage: agent-target
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass RS2-5 || fail_case RS2-5 "rc=$rc out=$out"

# RS2-6a — missing file → exit 1
out=$(bash "$PROBE" "$FIX/does-not-exist.md" 2>"$FIX/.err"); rc=$?
[ "$rc" = 1 ] && pass RS2-6a || fail_case RS2-6a "rc=$rc out=$out"
# RS2-6b — file with no frontmatter at all → exit 2
printf '# just a heading\nno frontmatter here\n' > "$SPEC"
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass RS2-6b || fail_case RS2-6b "rc=$rc out=$out"

# RS2-7 — plan: null prints plan=null; quoted plan prints unquoted
cat > "$SPEC" <<'EOF'
---
related-issue: 7
test-tiers:
  unit: required
implementation-mode: executing-plans
triage: everything-else
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'plan=null' && pass RS2-7a || fail_case RS2-7a "rc=$rc out=$out"
write_valid
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'plan=docs/plans/foo.md' && pass RS2-7b || fail_case RS2-7b "out=$out"

# RS2-8 — read-only
write_valid
before=$(shasum "$SPEC" | cut -d' ' -f1); bash "$PROBE" "$SPEC" >/dev/null 2>&1
after=$(shasum "$SPEC" | cut -d' ' -f1)
[ "$before" = "$after" ] && pass RS2-8 || fail_case RS2-8 "spec mutated"

# RS2-9 — kind: shaping → exit 3, no stdout, specific non-buildable message (#692)
cat > "$SPEC" <<'EOF'
---
related-issue: 680
kind: shaping
---
# shaping doc
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ] && grep -qi "shaping" "$FIX/.err"; then pass RS2-9; else fail_case RS2-9 "rc=$rc out=$out err=$(cat "$FIX/.err")"; fi

# RS2-10 — kind: buildable behaves as normal (regression) → exit 0, full schema (#692)
cat > "$SPEC" <<'EOF'
---
related-issue: 303
kind: buildable
test-tiers:
  unit: required
implementation-mode: direct
triage: agent-target
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'related-issue=303'; then pass RS2-10; else fail_case RS2-10 "rc=$rc out=$out err=$(cat "$FIX/.err")"; fi

# RS2-11 — invalid kind + otherwise-complete five fields → exit 2 (self-contained
# consumer gate; must not fall through to exit 0 / treated-as-buildable). (#692)
cat > "$SPEC" <<'EOF'
---
related-issue: 303
kind: epic
test-tiers:
  unit: required
implementation-mode: direct
triage: agent-target
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -qi "invalid kind" "$FIX/.err"; then pass RS2-11; else fail_case RS2-11 "rc=$rc out=$out err=$(cat "$FIX/.err")"; fi

# RS2-12 — mapping-valued kind + complete fields → exit 2 (must not read as
# absent ⇒ buildable). (#692, Codex review)
cat > "$SPEC" <<'EOF'
---
related-issue: 303
kind:
  value: shaping
test-tiers:
  unit: required
implementation-mode: direct
triage: agent-target
plan: null
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -qi "mapping" "$FIX/.err"; then pass RS2-12; else fail_case RS2-12 "rc=$rc out=$out err=$(cat "$FIX/.err")"; fi

[ "$fail" = 0 ] && echo "read-s2-frontmatter contract: ALL PASS" || exit 1
