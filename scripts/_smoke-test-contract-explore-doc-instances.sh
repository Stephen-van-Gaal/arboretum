#!/usr/bin/env bash
# owner: document-access
# scope: plugin-only
# ci-parallel: safe
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/explore-doc.sh"
READ_SECTIONS="$ROOT/scripts/read-doc-sections.sh"
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

# --- Test 1: governed spec instance resolves to governed-spec ---
SPEC_INSTANCE="$ROOT/docs/specs/document-access.spec.md"
out=$(bash "$PROBE" "$SPEC_INSTANCE" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=governed-spec$'; then
  pass "docs/specs/*.spec.md instance resolves to governed-spec"
else
  fail_case "governed-spec instance path inference" \
    "rc=$rc out=$(printf '%s\n' "$out" | head -3) err=$(cat "$FIX/err")"
fi

# --- Test 2: design-spec instance resolves to design-spec ---
DESIGN_INSTANCE="$ROOT/docs/superpowers/specs/2026-03-15-arbutus-migration-design.md"
out=$(bash "$PROBE" "$DESIGN_INSTANCE" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=design-spec$'; then
  pass "docs/superpowers/specs/*-design.md instance resolves to design-spec"
else
  fail_case "design-spec instance path inference" \
    "rc=$rc out=$(printf '%s\n' "$out" | head -3) err=$(cat "$FIX/err")"
fi

# --- Test 3: plan instance resolves to plan ---
PLAN_INSTANCE="$ROOT/docs/plans/2026-03-15-slash-skills-automation.md"
out=$(bash "$PROBE" "$PLAN_INSTANCE" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=plan$'; then
  pass "docs/plans/*.md instance resolves to plan"
else
  fail_case "plan instance path inference" \
    "rc=$rc out=$(printf '%s\n' "$out" | head -3) err=$(cat "$FIX/err")"
fi

# --- Test 4: read-doc-sections.sh resolves a catalog-only alias on real spec ---
# Request the `non-goals` alias: it resolves only when the governed-spec catalog
# shape is applied. An unknown-shape doc would key that heading as the
# heading-derived `boundaries-non-goals`, so this specifically asserts that
# instance inference produced a cataloged shape (stronger than `purpose`, which
# would resolve via heading-derived keys even on an unknown-shape doc).
out=$(bash "$READ_SECTIONS" "$SPEC_INSTANCE" non-goals 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -qi "## Boundaries (non-goals)"; then
  pass "read-doc-sections.sh resolves the governed-spec 'non-goals' alias on a real spec"
else
  fail_case "read-doc-sections.sh catalog-alias resolution on real spec" \
    "rc=$rc out=$(printf '%s\n' "$out" | head -5) err=$(cat "$FIX/err")"
fi

# --- Test 6: archived/nested spec paths stay unknown (single-segment glob) ---
ARCHIVED="$ROOT/docs/specs/_deprecated/two-path-governance.spec.md"
if [ -f "$ARCHIVED" ]; then
  out=$(bash "$PROBE" "$ARCHIVED" 2>"$FIX/err"); rc=$?
  if [ "$rc" = 0 ] \
    && printf '%s\n' "$out" | grep -q '^document-shape=unknown$'; then
    pass "nested/archived docs/specs/_deprecated/*.spec.md stays document-shape=unknown"
  else
    fail_case "archived spec path must not infer governed-spec" \
      "rc=$rc out=$(printf '%s\n' "$out" | head -3) err=$(cat "$FIX/err")"
  fi
fi

# --- Test 5: explicit frontmatter still wins over path convention ---
# Create a temp file with document-shape: governed-spec frontmatter.
# The path cannot mimic docs/specs/ but the frontmatter value should win.
TMPSPEC="$FIX/frontmatter-wins.md"
cat > "$TMPSPEC" <<'EOF'
---
document-shape: governed-spec
---
# Test Doc

## Purpose

Testing frontmatter precedence.
EOF

out=$(bash "$PROBE" "$TMPSPEC" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^document-shape=governed-spec$'; then
  pass "explicit document-shape frontmatter resolves correctly regardless of path"
else
  fail_case "frontmatter precedence over path convention" \
    "rc=$rc out=$(printf '%s\n' "$out" | head -3) err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "explore-doc instance-path inference contract: ALL PASS" || exit 1
