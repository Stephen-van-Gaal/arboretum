#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-definition-index.sh — Verify generate-register.sh emits
# a Definition Index table when docs/definitions/*.md is non-empty,
# and falls back to the placeholder when the directory is missing.
#
# Issue stvangaal/arboretum#10: earlier versions emitted a Definition
# Index listing each definition's version/status with Provided By
# and Required By columns derived from spec frontmatter. The current
# plugin removed it, breaking dependency-reasoning views for projects
# with shared contracts (e.g. conversations has 13 definitions).
#
# This smoke test asserts:
#   1. When docs/definitions/ is missing → placeholder comment emitted
#      (backwards compatible).
#   2. When docs/definitions/ contains *.md files → table emitted with
#      one row per definition; providers/requirers derived from spec
#      frontmatter `provides:` and `requires:` blocks.
#   3. Definitions with no providers/requirers show "—" sentinels.
#
# Usage: bash scripts/_smoke-test-definition-index.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"

[ -f "$GEN" ] || { echo "FAIL: $GEN not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Case 1: no docs/definitions/ → placeholder ───────────────────────

mkdir -p "$FIXTURE/docs/specs"
cat > "$FIXTURE/docs/specs/solo.spec.md" <<'EOF'
---
name: solo
status: active
owner: alice
owns:
  - src/solo.py
---

# solo

Fixture spec.
EOF

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero (case 1)"

REG=$(cat "$FIXTURE/docs/REGISTER.md")

# Header schema is consistent across empty and populated cases —
# adopting a project's first definition should not change column names.
echo "$REG" | grep -Eq '^\| Name \| Version \| Status \| Provided By \| Required By \|' \
  || fail "case 1: unified Definition Index header missing in placeholder path" "$REG"

echo "$REG" | grep -q "No shared definitions yet" \
  || fail "case 1: expected placeholder comment when docs/definitions/ is missing" "$REG"

# ── Case 2: docs/definitions/ with multiple files → table ────────────

mkdir -p "$FIXTURE/docs/definitions"

cat > "$FIXTURE/docs/definitions/blog-config.md" <<'EOF'
---
name: blog-config
version: v0
status: draft
---

# blog-config

Shared blog configuration shape.
EOF

cat > "$FIXTURE/docs/definitions/pubmed-record.md" <<'EOF'
---
name: pubmed-record
version: v1
status: active
---

# pubmed-record

Normalized PubMed record shape.
EOF

# Orphan definition — not referenced by any spec; should still appear
# in the index with em-dash sentinels for both providers and requirers.
cat > "$FIXTURE/docs/definitions/unused.md" <<'EOF'
---
name: unused
version: v0
status: draft
---

# unused
EOF

# Specs that provide / require the definitions via frontmatter.
cat > "$FIXTURE/docs/specs/blog-publish.spec.md" <<'EOF'
---
name: blog-publish
status: active
owner: alice
owns:
  - src/blog_publish.py
provides:
  - blog-config
requires:
  - pubmed-record
EOF
# Note: the spec frontmatter is intentionally left "unclosed" here so
# we can append more fields above — close it now:
cat >> "$FIXTURE/docs/specs/blog-publish.spec.md" <<'EOF'
---

# blog-publish

Fixture spec.
EOF

cat > "$FIXTURE/docs/specs/pubmed-query.spec.md" <<'EOF'
---
name: pubmed-query
status: active
owner: bob
owns:
  - src/pubmed_query.py
provides:
  - pubmed-record
---

# pubmed-query

Fixture spec.
EOF

cat > "$FIXTURE/docs/specs/llm-triage.spec.md" <<'EOF'
---
name: llm-triage
status: active
owner: carol
owns:
  - src/llm_triage.py
requires:
  - pubmed-record
---

# llm-triage

Fixture spec.
EOF

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero (case 2)"

REG=$(cat "$FIXTURE/docs/REGISTER.md")

# Same header schema as case 1 — programmatic consumers shouldn't have
# to special-case "empty" vs "populated" register output.
echo "$REG" | grep -Eq '^\| Name \| Version \| Status \| Provided By \| Required By \|' \
  || fail "case 2: expected unified Definition Index header" "$REG"

# Placeholder must NOT appear when definitions exist.
echo "$REG" | grep -q "No shared definitions yet" \
  && fail "case 2: placeholder leaked into populated table" "$REG"

# blog-config: provided by blog-publish, required by nothing.
echo "$REG" | grep -Eq '^\| blog-config \| v0 \| draft \| blog-publish \| — \|' \
  || fail "case 2: blog-config row missing or malformed" "$(echo "$REG" | grep blog-config || echo '<no match>')"

# pubmed-record: provided by pubmed-query, required by blog-publish + llm-triage.
echo "$REG" | grep -Eq '^\| pubmed-record \| v1 \| active \| pubmed-query \| (blog-publish, llm-triage|llm-triage, blog-publish) \|' \
  || fail "case 2: pubmed-record row missing or malformed" "$(echo "$REG" | grep pubmed-record || echo '<no match>')"

# unused: orphan — both columns em-dash.
echo "$REG" | grep -Eq '^\| unused \| v0 \| draft \| — \| — \|' \
  || fail "case 2: unused (orphan) definition row missing or malformed" "$(echo "$REG" | grep unused || echo '<no match>')"

# ── Case 3: empty docs/definitions/ directory → placeholder ──────────

rm -f "$FIXTURE/docs/definitions/"*.md

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero (case 3)"

REG=$(cat "$FIXTURE/docs/REGISTER.md")
echo "$REG" | grep -q "No shared definitions yet" \
  || fail "case 3: expected placeholder when docs/definitions/ is empty" "$REG"

echo "PASS: definition index — placeholder, populated table, orphan handling, empty-dir fallback"
