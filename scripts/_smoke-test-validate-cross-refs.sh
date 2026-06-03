#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-validate-cross-refs.sh — Exercise Check 4 (dependency
# notation consistency) in validate-cross-refs.sh.
#
# Issue stvangaal/arboretum#11: the original Check 4 parsed a "Depends On"
# column that was removed in the 4-column REGISTER schema migration.
# This restored Check 4 reads spec frontmatter `requires:` and
# `provides:` blocks and validates entry notation:
#
#   - Path-shaped entries (containing "/") must end in .md
#   - Versioned entries (containing "@") must match @v<N> exactly
#   - Bare names need no further check
#
# Usage: bash scripts/_smoke-test-validate-cross-refs.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-cross-refs.sh"

[ -f "$VALIDATE" ] || { echo "FAIL: $VALIDATE not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/docs/definitions"

for definition in explicit-path wp-config blog-config literature-summary blog-page; do
  cat > "$FIXTURE/docs/definitions/${definition}.md" <<EOF
---
name: ${definition}
version: v1
status: draft
---

# ${definition}

Fixture definition for the smoke test.
EOF
done

# ── Case 1: All well-formed entries → Check 4 passes + RC=0 ──────────

cat > "$FIXTURE/docs/specs/good.spec.md" <<'EOF'
---
name: good
status: active
owner: alice
provides:
  - bare-name
  - bare-name@v0
  - bare-name@v1
  - definitions/explicit-path.md
  - definitions/explicit-path.md@v1
requires:
  - another-bare
  - another-bare@v2
---

# good

Fixture spec with all well-formed dep notations, including the
versioned-path form (regression for stvangaal/arboretum#11 review
feedback). Note: example notation is in the frontmatter above; do not
write versioned-path examples in body text — Check 1's reference
scanner would treat them as real refs and look for nonexistent files.

Line-range citations to definitions should be treated as references to
the base definition file, not as literal filenames:
docs/definitions/wp-config.md:28-42 and docs/definitions/wp-config.md:6-8.
EOF

cat > "$FIXTURE/docs/specs/blog-publish.spec.md" <<'EOF'
---
name: blog-publish
status: active
owner: alice
---

# blog-publish

## Requires

| Definition | Version |
|---|---|
| definitions/blog-config@v0 | required |
| definitions/literature-summary@v2 | required |

## Provides

| Definition | Version |
|---|---|
| definitions/blog-page@v0 | provided |
EOF

cat > "$FIXTURE/contracts.yaml" <<'EOF'
version: 1
specs:
  blog-publish:
    requires:
      definitions/blog-config: v0
      definitions/literature-summary: v2
    provides:
      definitions/blog-page: v0
EOF

set +e
OUT=$(bash "$VALIDATE" "$FIXTURE" 2>&1)
RC=$?
set -e

# Whole-script exit code matters: a green Check inside a failing script
# is still a failing script for CI gating.
[ "$RC" -eq 0 ] \
  || fail "case 1: validate-cross-refs exited $RC, expected 0 on well-formed fixture" "$OUT"

# Check 4 must run and report green for this fixture.
echo "$OUT" | grep -q "Check 4: Dependency notation consistency" \
  || fail "case 1: Check 4 header not in output" "$OUT"

echo "$OUT" | grep -q "All frontmatter dep notations are well-formed" \
  || fail "case 1: Check 4 did not pass on well-formed fixture" "$OUT"

# ── Case 2: Each malformed shape produces a distinct warning ─────────

cat > "$FIXTURE/docs/specs/bad.spec.md" <<'EOF'
---
name: bad
status: active
owner: bob
requires:
  - definitions/unsuffixed
  - missing-v-prefix@1
  - empty-version@v
  - non-numeric-version@vX
  - trailing-garbage@v1x
provides:
  - good-one
---

# bad

Fixture spec with malformed dep notations — one per supported failure shape.
EOF

set +e
OUT=$(bash "$VALIDATE" "$FIXTURE" 2>&1)
RC=$?
set -e

# validate-cross-refs.sh exits 1 when any check finds issues; we expect
# all 5 malformed entries to be flagged, plus the Check 4 summary line
# to NOT report green.
[ "$RC" -ne 0 ] || fail "case 2: validate exited 0 but expected non-zero on malformed input" "$OUT"

# Per-entry assertions. The exact warning wording is part of the
# contract — downstream tools/CI may grep on these lines.
echo "$OUT" | grep -q 'bad.spec.md: requires entry "definitions/unsuffixed" looks like a path but lacks .md suffix' \
  || fail "case 2: missing .md suffix not flagged" "$OUT"

echo "$OUT" | grep -q 'bad.spec.md: requires entry "missing-v-prefix@1" has malformed version' \
  || fail "case 2: missing v-prefix not flagged" "$OUT"

echo "$OUT" | grep -q 'bad.spec.md: requires entry "empty-version@v" has malformed version' \
  || fail "case 2: empty version not flagged" "$OUT"

echo "$OUT" | grep -q 'bad.spec.md: requires entry "non-numeric-version@vX" has malformed version' \
  || fail "case 2: non-numeric version not flagged" "$OUT"

echo "$OUT" | grep -q 'bad.spec.md: requires entry "trailing-garbage@v1x" has malformed version' \
  || fail "case 2: trailing-garbage version not flagged" "$OUT"

# The well-formed provides entry must NOT produce a false positive.
echo "$OUT" | grep -q '"good-one"' \
  && fail "case 2: bare-name 'good-one' incorrectly flagged" "$OUT"

# ── Case 3: Spec without requires/provides → Check 4 silently passes ─

rm -f "$FIXTURE/docs/specs/bad.spec.md"
cat > "$FIXTURE/docs/specs/silent.spec.md" <<'EOF'
---
name: silent
status: draft
owner: carol
owns:
  - src/silent.py
---

# silent

Fixture spec with no frontmatter requires/provides — Check 4 has nothing to validate.
EOF

# good.spec.md from case 1 still exists. Combined with silent.spec.md,
# Check 4 should still report green.
set +e
OUT=$(bash "$VALIDATE" "$FIXTURE" 2>&1)
set -e

echo "$OUT" | grep -q "All frontmatter dep notations are well-formed" \
  || fail "case 3: Check 4 unexpectedly failed when one spec has no requires/provides" "$OUT"

echo "PASS: validate-cross-refs Check 4 — well-formed entries, malformed-shape coverage, no-requires fallback"
