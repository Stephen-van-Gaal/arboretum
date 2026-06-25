#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# uses: definitions/register-schema.md @v1
# uses: definitions/contracts-yaml-schema.md @v1
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
    # Angle brackets are excluded for the same reason: a prose placeholder
    # like `definitions/<name>.md` describing the reference *format* is not
    # a real reference, and `<name>.md` will never resolve on disk. With
    # `<` excluded the regex simply fails to match at `definitions/<…`,
    # so the placeholder contributes no reference at all.
    def_refs=$(grep -oE 'definitions/[^@|<>:[:space:],)`]+' "$spec_file" 2>/dev/null \
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
      | awk '
          /^    requires:/ { in_requires = 1; next }
          /^    [^ ]/ { in_requires = 0 }
          in_requires { print }
        ' \
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
      | awk '
          /^    provides:/ { in_provides = 1; next }
          /^    [^ ]/ { in_provides = 0 }
          in_provides { print }
        ' \
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

# ── Check 4: Dependency notation consistency ────────────────────────
#
# Validates each entry in every spec's frontmatter `requires:` and
# `provides:` blocks against three conventions:
#
#   1. Path-shaped (contains "/") → must end in .md
#        good: definitions/pubmed-record.md
#        bad:  definitions/pubmed-record   (missing .md)
#
#   2. Versioned (contains "@") → must match @v<N> exactly
#        good: pubmed-record@v0, pubmed-record@v1
#        bad:  pubmed-record@1, pubmed-record@v, pubmed-record@vX
#
#   3. Bare name (no "/", no "@") → no further check; treated as a
#      definition reference resolvable via the Definition Index.
#
# The previous Check 4 parsed a REGISTER.md "Depends On" column that
# was removed in the 4-column schema migration. Dependency tracking
# now lives in spec frontmatter — Check 4 follows.

echo ""
echo "━━━ Check 4: Dependency notation consistency ━━━"

if [ ! -d "$SPECS_DIR" ]; then
  info "No specs directory — skipping"
else
  check4_issues=0

  # Inline YAML-list extractor. The parsing pattern mirrors
  # generate-register.sh's extract_owns_list (loop frontmatter, look
  # for `<field>:`, collect `- item` lines until indentation drops);
  # this function generalizes it to any list field. Keeping
  # validate-cross-refs.sh self-contained avoids pulling in
  # generate-register's argument-parsing side effects.
  extract_yaml_list() {
    local file="$1"
    local field="$2"
    local in_fm=false
    local fm_delims=0
    local in_field=false

    while IFS= read -r line; do
      if [[ "$line" == "---" ]]; then
        ((fm_delims++)) || true
        if [ "$fm_delims" -eq 1 ]; then in_fm=true; continue; fi
        if [ "$fm_delims" -eq 2 ]; then break; fi
      fi
      [ "$in_fm" = false ] && continue

      if [[ "$line" =~ ^${field}: ]]; then
        in_field=true
        continue
      fi
      if [ "$in_field" = true ]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]](.+) ]]; then
          local item="${BASH_REMATCH[1]}"
          item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [ -n "$item" ] && echo "$item"
        elif [[ "$line" =~ ^[^[:space:]] ]]; then
          in_field=false
        fi
      fi
    done < "$file"
  }

  validate_dep_entry() {
    local spec_name="$1"
    local field="$2"      # "requires" or "provides"
    local entry="$3"

    # Strip an optional @vN suffix before path validation, so versioned
    # path notation like `definitions/foo.md@v1` is accepted: the path
    # portion before @ is what the .md suffix rule applies to.
    local path_part="${entry%@*}"
    local version_part=""
    if [[ "$entry" == *"@"* ]]; then
      version_part="${entry##*@}"
    fi

    # Path-shaped entries must end in .md.
    if [[ "$path_part" == */* ]]; then
      if [[ "$path_part" != *.md ]]; then
        warn "$spec_name: $field entry \"$entry\" looks like a path but lacks .md suffix"
        return 1
      fi
    fi

    # Versioned entries must match v<N> exactly. Anchoring the regex
    # on the portion after @ also rejects trailing garbage (v1x, v1.0).
    if [ -n "$version_part" ]; then
      if ! [[ "$version_part" =~ ^v[0-9]+$ ]]; then
        warn "$spec_name: $field entry \"$entry\" has malformed version (expected @v<N>, got @${version_part})"
        return 1
      fi
    fi

    return 0
  }

  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ ! -f "$spec_file" ] && continue
    spec_name=$(basename "$spec_file")

    for field in requires provides; do
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        validate_dep_entry "$spec_name" "$field" "$entry" \
          || ((check4_issues++)) || true
      done < <(extract_yaml_list "$spec_file" "$field")
    done
  done

  [ "$check4_issues" -eq 0 ] && ok "All frontmatter dep notations are well-formed"
fi

# ── Check 5: group-spec layer membership integrity (#681) ────────────
# Bidirectional parent/contains + group owns: ⇄ # owner: glue (D7). Vacuous
# on a group-free repo. Folds into the global issues counter via warn().
if bash "$(dirname "${BASH_SOURCE[0]}")/validate-group-membership.sh" "$PROJECT_DIR" >/dev/null 2>&1; then
  ok "Group-spec layer membership integrity holds"
else
  warn "Group-spec layer membership integrity violations — run scripts/validate-group-membership.sh"
fi

# ── Check 6: Decisions Status + supersession-link integrity (#682) ───
# Deterministic, no semantic inference: Status must parse to the enum, and any
# superseded→Dxx must resolve to a real in-table ID. (Design D3/D7.)
echo ""
echo "━━━ Check 6: Decisions Status integrity ━━━"
check6_issues=0
if [ -d "$SPECS_DIR" ]; then
  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ -f "$spec_file" ] || continue
    while IFS= read -r msg; do
      [ -z "$msg" ] && continue
      warn "$msg"
      ((check6_issues++)) || true
    done < <(python3 - "$spec_file" <<'PY'
import sys, re

path = sys.argv[1]
name = path.rsplit("/", 1)[-1]
with open(path, encoding="utf-8") as h:
    lines = h.read().splitlines()

# Slice the level-2 "## Decisions" section: from its heading to the next
# same-or-higher heading (## or #).
sec, grab = [], False
for ln in lines:
    if re.match(r"^##\s+Decisions\b", ln):
        grab = True
        continue
    if grab and re.match(r"^#{1,2}\s+\S", ln):
        break
    if grab:
        sec.append(ln)

header, rows = None, []
for ln in sec:
    s = ln.strip()
    if not s.startswith("|"):
        continue
    # Split on unescaped pipes only — a cell may contain an escaped \| (valid
    # Markdown), which must not be treated as a column boundary.
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", s.strip("|"))]
    if set("".join(cells)) <= set("-: "):
        continue
    if header is None:
        header = [re.sub(r"\s+", " ", c).strip().casefold() for c in cells]
        continue
    rows.append(cells)

if header is None or not rows:
    sys.exit(0)

def col(n):
    try:
        return header.index(n)
    except ValueError:
        return None

i_id, i_status = col("id"), col("status")
if i_id is None or i_status is None:
    sys.exit(0)  # no Status column → nothing to check (flat #671 table)

def cell(c, idx):
    return c[idx] if (idx is not None and idx < len(c)) else ""

ids = {cell(c, i_id) for c in rows}
for c in rows:
    did, status = cell(c, i_id), cell(c, i_status)
    if status in ("", "active", "moot"):
        continue
    m = re.match(r"^superseded→(D\d+)$", status)
    if m:
        if m.group(1) not in ids:
            print("%s: decision %s is superseded by missing %s" % (name, did, m.group(1)))
    else:
        print("%s: decision %s has invalid Status '%s'" % (name, did, status))
PY
)
  done
fi
[ "$check6_issues" -eq 0 ] && ok "All Decisions Status values + supersession links are valid"

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
