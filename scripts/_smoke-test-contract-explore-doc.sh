#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/explore-doc.sh"
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

out=$(bash "$PROBE" "$ROOT/docs/templates/spec.md" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=governed-spec$' \
  && printf '%s\n' "$out" | grep -q 'section\[[0-9][0-9]*\]\.key=purpose' \
  && printf '%s\n' "$out" | grep -q 'section\[[0-9][0-9]*\]\.key=behaviour' \
  && printf '%s\n' "$out" | grep -q 'section\[[0-9][0-9]*\]\.alias=non-goals'; then
  pass "cataloged template exposes shape, semantic keys, and aliases"
else
  fail_case "cataloged template discovery" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

FREE="$FIX/free.md"
cat > "$FREE" <<'EOF'
# Free Document

## Local Value

Body.
EOF

out=$(bash "$PROBE" "$FREE" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=unknown$' \
  && printf '%s\n' "$out" | grep -q 'section\[[0-9][0-9]*\]\.key=free-document' \
  && printf '%s\n' "$out" | grep -q 'section\[[0-9][0-9]*\]\.key=local-value' \
  && printf '%s\n' "$out" | grep -q 'warning\[\]=unmapped-heading:Local Value'; then
  pass "uncataloged documents expose heading-derived keys with warnings"
else
  fail_case "uncataloged heading discovery" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

FAKE_ROOT="$FIX/root"
mkdir -p "$FAKE_ROOT/scripts/lib" "$FAKE_ROOT/docs/templates"
cp "$ROOT/scripts/explore-doc.sh" "$FAKE_ROOT/scripts/explore-doc.sh"
cp "$ROOT/scripts/lib/yaml-lite.sh" "$FAKE_ROOT/scripts/lib/yaml-lite.sh"
cp "$ROOT/docs/templates/document-shapes.yaml" "$FAKE_ROOT/docs/templates/document-shapes.yaml"
chmod +x "$FAKE_ROOT/scripts/explore-doc.sh" "$FAKE_ROOT/scripts/lib/yaml-lite.sh"
cat > "$FAKE_ROOT/docs/templates/spec.md" <<'EOF'
# Governed Spec Template

## Purpose

Purpose body.

## Behaviour

Behaviour body.
EOF

out=$(bash "$FAKE_ROOT/scripts/explore-doc.sh" "$FAKE_ROOT/docs/templates/spec.md" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=governed-spec$'; then
  pass "shape can be inferred from catalog template path without frontmatter"
else
  fail_case "shape inference by template path" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

DUP="$FIX/duplicate.md"
cat > "$DUP" <<'EOF'
---
document-shape: governed-spec
---
# Duplicate

## Purpose

First body.

## purpose

Second body.
EOF

out=$(bash "$PROBE" "$DUP" 2>"$FIX/err"); rc=$?
if [ "$rc" != 0 ] \
  && grep -qi "ambiguous" "$FIX/err" \
  && grep -q "purpose" "$FIX/err"; then
  pass "duplicate catalog heading matches fail as ambiguous"
else
  fail_case "duplicate semantic match should fail" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "explore-doc contract: ALL PASS" || exit 1
