#!/usr/bin/env bash
# owner: pipeline-contracts-template
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/read-doc-profile.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && {
    echo "--- detail ---" >&2
    echo "$2" >&2
  }
  fail=1
}

DOC="$FIX/doc.md"
cat > "$DOC" <<'EOF'
---
read_profiles:
  compact:
    sections:
      - Purpose
      - 'Edge Cases: punctuation & symbols?'
  normalized:
    sections:
      - purpose
      - nested   detail
  nested-only:
    sections:
      - Nested Detail
  unresolved:
    sections:
      - Purpose
      - Missing Section
---
# Fixture Document

Introductory body.

## Purpose

Purpose body.

### Nested Detail

Nested body.

## Edge Cases: punctuation & symbols?

Punctuation body.

## Next Section

Next body should not leak into the profile output.
EOF

NO_PROFILE="$FIX/no-profile.md"
cat > "$NO_PROFILE" <<'EOF'
---
name: no-profile
---
# No Profile

## Purpose

Body.
EOF

BLANK_ENTRY="$FIX/blank-entry.md"
cat > "$BLANK_ENTRY" <<'EOF'
---
read_profiles:
  blank-only:
    sections:
      - ''
---
# Blank Entry

## Purpose

Body.
EOF

out=$(bash "$PROBE" "$DOC" "compact" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Purpose$' \
  && printf '%s\n' "$out" | grep -q '^## Edge Cases: punctuation & symbols?$' \
  && printf '%s\n' "$out" | grep -q '^### Nested Detail$' \
  && ! printf '%s\n' "$out" | grep -q '^---$' \
  && ! printf '%s\n' "$out" | grep -q '^## Next Section$'; then
  pass "profile concatenates compact requested sections"
else
  fail_case "compact profile extraction" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "nested-only" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^### Nested Detail$' \
  && ! printf '%s\n' "$out" | grep -q '^## Purpose$'; then
  pass "profiles may target nested section headings exactly"
else
  fail_case "nested profile extraction" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "normalized" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Purpose$' \
  && printf '%s\n' "$out" | grep -q '^### Nested Detail$' \
  && ! printf '%s\n' "$out" | grep -q '^## Edge Cases: punctuation & symbols?$'; then
  pass "profiles resolve section names with normalized heading matching"
else
  fail_case "normalized profile extraction" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "missing-profile" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "missing-profile" "$FIX/err"; then
  pass "invalid profile name fails clearly"
else
  fail_case "invalid profile should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "unresolved" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "Missing Section" "$FIX/err"; then
  pass "unresolved profile section references fail clearly"
else
  fail_case "unresolved profile section should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$NO_PROFILE" "compact" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "read_profiles" "$FIX/err"; then
  pass "documents without read_profiles reject profile reads"
else
  fail_case "missing read_profiles should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$BLANK_ENTRY" "blank-only" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -qi "blank" "$FIX/err"; then
  pass "blank profile section entries fail clearly"
else
  fail_case "blank profile section entry should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "read-doc-profile contract: ALL PASS" || exit 1
