#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/read-doc-section.sh"
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
---
# Fixture Document

Introductory body that is not part of a requested section.

## Purpose

Purpose body.

### Nested Detail

Nested body stays inside the Purpose section.

## Edge Cases: punctuation & symbols?

Punctuation body.

## Next Section

Next body should not leak into earlier sections.
EOF

DUP="$FIX/duplicate.md"
cat > "$DUP" <<'EOF'
# Duplicate Fixture

## Repeated

First repeated body.

### Repeated

Second repeated body.
EOF

NORMALIZED="$FIX/normalized.md"
cat > "$NORMALIZED" <<'EOF'
# Normalized Fixture

##   Mixed   Case   Heading   

Normalized body.

## Boundary

Boundary body.
EOF

NORMALIZED_DUP="$FIX/normalized-duplicate.md"
cat > "$NORMALIZED_DUP" <<'EOF'
# Normalized Duplicate Fixture

## Purpose

Upper body.

## purpose

Lower body.
EOF

FRONTMATTER_ONLY="$FIX/frontmatter-only.md"
cat > "$FRONTMATTER_ONLY" <<'EOF'
---
read_profiles:
  compact:
    sections:
      - Purpose
---
EOF

LONG_FENCE="$FIX/long-fence.md"
cat > "$LONG_FENCE" <<'EOF'
# Long Fence Fixture

## Purpose

````markdown
```text
inner fence example
## Hidden Heading
```
still inside the longer fence
````

Purpose tail after fenced example.

## Next Section

Next body should not leak into Purpose.
EOF

out=$(bash "$PROBE" "$DOC" "Purpose" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Purpose$' \
  && printf '%s\n' "$out" | grep -q '^### Nested Detail$' \
  && ! printf '%s\n' "$out" | grep -q '^---$' \
  && ! printf '%s\n' "$out" | grep -q '^## Edge Cases: punctuation & symbols?$'; then
  pass "section extraction keeps nested headings and omits frontmatter/next sibling"
else
  fail_case "section extraction with nested headings" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "Edge Cases: punctuation & symbols?" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Edge Cases: punctuation & symbols?$' \
  && printf '%s\n' "$out" | grep -q 'Punctuation body' \
  && ! printf '%s\n' "$out" | grep -q '^## Next Section$'; then
  pass "section names with punctuation are exact-match selectable"
else
  fail_case "punctuation section extraction" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$NORMALIZED" "mixed case heading" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q 'Mixed   Case   Heading' \
  && printf '%s\n' "$out" | grep -q 'Normalized body' \
  && ! printf '%s\n' "$out" | grep -q '^## Boundary$'; then
  pass "heading matching is case-insensitive and whitespace-normalized"
else
  fail_case "normalized heading matching" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DOC" "Missing Section" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "Missing Section" "$FIX/err"; then
  pass "missing section fails clearly"
else
  fail_case "missing section should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$DUP" "Repeated" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -qi "duplicate" "$FIX/err"; then
  pass "duplicate section headings fail as ambiguous"
else
  fail_case "duplicate section should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$NORMALIZED_DUP" "PURPOSE" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -qi "duplicate" "$FIX/err"; then
  pass "normalized duplicate headings fail as ambiguous"
else
  fail_case "normalized duplicate section should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$FRONTMATTER_ONLY" "Purpose" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "Purpose" "$FIX/err"; then
  pass "frontmatter-only docs do not produce phantom sections"
else
  fail_case "frontmatter-only missing section should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$LONG_FENCE" "Purpose" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Hidden Heading$' \
  && printf '%s\n' "$out" | grep -q 'Purpose tail after fenced example' \
  && ! printf '%s\n' "$out" | grep -q '^## Next Section$'; then
  pass "longer fenced blocks ignore shorter nested fences before closing"
else
  fail_case "longer fenced block should not close on shorter nested fence" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$LONG_FENCE" "Hidden Heading" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && [ -z "$out" ] \
  && grep -q "Hidden Heading" "$FIX/err"; then
  pass "headings inside longer fenced blocks are not selectable"
else
  fail_case "heading inside longer fenced block should not be selectable" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "read-doc-section contract: ALL PASS" || exit 1
