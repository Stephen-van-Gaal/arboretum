#!/usr/bin/env bash
# owner: document-taxonomy
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-concept-catalog.sh -- Verify concept catalog anchors do not drift silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

ok() {
  echo "PASS: $1"
}

CATALOG="docs/definitions/concept-catalog.md"
[ -f "$CATALOG" ] || fail "$CATALOG missing"

ids="$(
  awk '
    BEGIN { in_catalog=0 }
    /^## Catalog$/ { in_catalog=1; next }
    in_catalog && /^## / { exit }
    in_catalog && /^\| [a-z0-9][a-z0-9-]+ / {
      split($0, parts, "|")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[2])
      if (parts[2] != "---") print parts[2]
    }
  ' "$CATALOG"
)"

[ -n "$ids" ] || fail "no concept IDs found in catalog"

dupes="$(printf '%s\n' "$ids" | sort | uniq -d)"
[ -z "$dupes" ] || fail "duplicate concept IDs: $dupes"
ok "concept IDs are unique"

required_ids="
roadmap-idea
tracker-label
readiness-state
workflow-route
document-shape
customer-operator-experience
public-report
shared-definition
concept-catalog
"

for id in $required_ids; do
  printf '%s\n' "$ids" | grep -qx "$id" || fail "required concept ID missing: $id"
done
ok "required seed concepts exist"

for path in \
  docs/templates/README.md \
  docs/specs/document-taxonomy.spec.md \
  docs/specs/roadmap.spec.md \
  docs/specs/intake-report.spec.md; do
  [ -f "$path" ] || fail "required authority surface missing: $path"
done
ok "required authority surfaces exist"

for spec in \
  docs/specs/document-taxonomy.spec.md \
  docs/specs/roadmap.spec.md \
  docs/specs/intake-report.spec.md; do
  grep -q 'definitions/concept-catalog.md@v1' "$spec" \
    || fail "$spec does not cite definitions/concept-catalog.md@v1"
done
ok "concept-heavy specs cite the catalog definition"

grep -q 'docs/definitions/concept-catalog.md' docs/templates/README.md \
  || fail "taxonomy README does not point readers at the concept catalog"
ok "taxonomy entry point points to the catalog"

if grep -qiE 'trace links.*implemented|resolver tooling.*implemented' "$CATALOG"; then
  fail "catalog must not claim deferred Trace Links or Resolver Tooling are implemented"
fi
ok "deferred slices remain deferred"

echo "concept catalog smoke: ALL PASS"
