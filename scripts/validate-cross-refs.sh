#!/usr/bin/env bash
# validate-cross-refs.sh — Cross-document consistency checks
#
# Requires bash 4+.
#
# Usage:
#   ./scripts/validate-cross-refs.sh [project-dir]
#
# Checks:
#   1. Every definition referenced in a spec Requires table exists in docs/definitions/
#   2. Every spec listed in REGISTER.md exists in docs/specs/
#   3. contracts.yaml entries match actual spec Requires/Provides
#
# Exit code: 0 if consistent, 1 if issues found.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash." >&2
  exit 1
fi

PROJECT_DIR="${1:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
SPECS_DIR="$PROJECT_DIR/docs/specs"

issues=0

ok() {
  echo "  ✓ $1"
}

warn() {
  echo "  ✗ $1"
  ((issues++)) || true
}

info() {
  echo "  · $1"
}

# ── Check 1: Definition references in specs exist on disk ────────────

echo ""
echo "━━━ Check 1: Spec definition references exist ━━━"

if [ ! -d "$SPECS_DIR" ]; then
  info "No specs directory — skipping"
else
  check1_issues=0
  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ ! -f "$spec_file" ] && continue
    spec_name=$(basename "$spec_file")

    # Extract all definition references from Requires and Provides tables.
    # The regex captures `definitions/...`; the script later prefixes with
    # $PROJECT_DIR/docs/ when checking existence (see line ~70). Backtick is
    # excluded from the character class so that a trailing backtick in a
    # markdown-wrapped reference like `definitions/foo` is not consumed into
    # the captured reference (would otherwise produce a false positive
    # missing-file error of the shape "definitions/foo`.md does not exist").
    def_refs=$(grep -oE 'definitions/[^@|[:space:])`]+' "$spec_file" 2>/dev/null \
      | sort -u || true)

    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      # Normalize: ensure .md extension
      def_file="$ref"
      [[ "$def_file" != *.md ]] && def_file="${def_file}.md"
      full_path="$PROJECT_DIR/docs/$def_file"

      if [ ! -f "$full_path" ]; then
        warn "$spec_name references $ref but $def_file does not exist"
        ((check1_issues++)) || true
      fi
    done <<< "$def_refs"
  done
  [ "$check1_issues" -eq 0 ] && ok "All definition references resolve to existing files"
fi

# ── Check 2: Specs in REGISTER.md exist on disk ─────────────────────

echo ""
echo "━━━ Check 2: Register specs exist on disk ━━━"

if [ ! -f "$REGISTER" ]; then
  info "No REGISTER.md — skipping"
else
  check2_issues=0
  # Extract spec names from register table rows (second column of pipe-delimited table)
  register_specs=$(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

  while IFS='|' read -r _ spec _; do
    spec=$(echo "$spec" | xargs)
    [ -z "$spec" ] && continue

    spec_file="$SPECS_DIR/$spec"
    if [ ! -f "$spec_file" ]; then
      warn "REGISTER.md lists $spec but file does not exist in docs/specs/"
      ((check2_issues++)) || true
    fi
  done <<< "$register_specs"

  [ "$check2_issues" -eq 0 ] && ok "All register specs exist on disk"
fi

# ── Check 3: contracts.yaml matches spec Requires/Provides ──────────

echo ""
echo "━━━ Check 3: contracts.yaml matches spec tables ━━━"

if [ ! -f "$CONTRACTS" ]; then
  info "No contracts.yaml — skipping"
elif [ ! -d "$SPECS_DIR" ]; then
  info "No specs directory — skipping"
else
  check3_issues=0

  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ ! -f "$spec_file" ] && continue
    spec_name=$(basename "$spec_file" .md)
    short_name="${spec_name%.spec}"

    # Get requires pins from spec
    spec_requires=$(sed -n '/^## Requires/,/^## /p' "$spec_file" \
      | grep -oE 'definitions/[^@|[:space:]]+@v[0-9]+' 2>/dev/null | sort -u || true)

    # Get requires pins from contracts.yaml for this spec
    yaml_section=$(sed -n "/^  ${short_name}:/,/^  [^ ]/p" "$CONTRACTS" 2>/dev/null || true)
    yaml_requires=$(echo "$yaml_section" \
      | sed -n '/requires:/,/provides:\|^  [^ ]/p' \
      | grep -oE 'definitions/[^:[:space:]]+: *v[0-9]+' 2>/dev/null \
      | sed 's/: */:/; s/:/\@/' | sort -u || true)

    # Compare requires
    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      if ! echo "$yaml_requires" | grep -qF "$pin"; then
        warn "$spec_name: requires $pin but contracts.yaml disagrees or is missing it"
        ((check3_issues++)) || true
      fi
    done <<< "$spec_requires"

    # Check for contracts.yaml entries not in spec
    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      if ! echo "$spec_requires" | grep -qF "$pin"; then
        warn "contracts.yaml has $pin for $short_name but spec does not require it"
        ((check3_issues++)) || true
      fi
    done <<< "$yaml_requires"

    # Same for provides
    spec_provides=$(sed -n '/^## Provides/,/^## /p' "$spec_file" \
      | grep -oE 'definitions/[^@|[:space:]]+@v[0-9]+' 2>/dev/null | sort -u || true)

    yaml_provides=$(echo "$yaml_section" \
      | sed -n '/provides:/,/^  [^ ]/p' \
      | grep -oE 'definitions/[^:[:space:]]+: *v[0-9]+' 2>/dev/null \
      | sed 's/: */:/; s/:/\@/' | sort -u || true)

    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      if ! echo "$yaml_provides" | grep -qF "$pin"; then
        warn "$spec_name: provides $pin but contracts.yaml disagrees or is missing it"
        ((check3_issues++)) || true
      fi
    done <<< "$spec_provides"
  done

  [ "$check3_issues" -eq 0 ] && ok "contracts.yaml matches all spec tables"
fi

# Note: a previous Check 4 validated REGISTER.md dependency-notation
# consistency by parsing a "Depends On" column. That column was removed
# when generate-register.sh moved to the 4-column schema (Spec | Status |
# Owner | Owns); dependency tracking now lives in spec frontmatter and in
# the human-readable "Dependency Resolution Order" section of REGISTER.md
# (which is prose, not a structured contract). The check therefore became
# a silent no-op and was removed in the same commit that surfaced this.

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$issues" -gt 0 ]; then
  echo "ISSUES FOUND: $issues cross-reference problems detected."
  exit 1
else
  echo "CONSISTENT: All cross-reference checks passed."
  exit 0
fi
