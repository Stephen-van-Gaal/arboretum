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

grep -q '^version: v2$' "$CATALOG" \
  || fail "concept catalog frontmatter is not v2"
grep -q '^## Version$' "$CATALOG" \
  || fail "concept catalog missing Version section"
grep -A1 '^## Version$' "$CATALOG" | grep -q '^v2$' \
  || fail "concept catalog Version section is not v2"

bash scripts/read-doc-profile.sh "$CATALOG" compact >/dev/null \
  || fail "concept catalog compact profile is not readable"

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
pipeline-stage
branch-mode
agent-ready
patch-lane
design-session-document
design-package
durable-document-change-set
document-shape
customer-operator-experience
bounded-read
read-profile
semantic-section-key
public-report
release-intent
review-cadence
controlled-vocabulary-inventory
shared-definition
concept-catalog
"

for id in $required_ids; do
  printf '%s\n' "$ids" | grep -qx "$id" || fail "required concept ID missing: $id"
done
ok "required seed concepts exist"

awk '
  BEGIN { in_catalog=0; bad=0 }
  /^## Catalog$/ { in_catalog=1; next }
  in_catalog && /^## / { exit }
  in_catalog && /^\| [a-z0-9][a-z0-9-]+ / {
    split($0, parts, "|")
    for (i = 2; i <= 7; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
      if (parts[i] == "") {
        print "empty catalog field in row: " $0 > "/dev/stderr"
        bad=1
      }
    }
  }
  END { exit bad }
' "$CATALOG" || fail "catalog rows must not have empty fields"
ok "catalog rows have required fields"

for path in \
  docs/definitions/README.md \
  docs/templates/README.md \
  docs/specs/document-taxonomy.spec.md \
  docs/specs/roadmap.spec.md \
  docs/specs/intake-report.spec.md \
  docs/specs/workflow-unification.spec.md \
  docs/specs/document-access.spec.md \
  docs/specs/arboretum-as-plugin.spec.md \
  docs/specs/git-workflow-tooling.spec.md; do
  [ -f "$path" ] || fail "required authority surface missing: $path"
done
ok "required authority surfaces exist"

readme_compact="$(bash scripts/read-doc-profile.sh docs/definitions/README.md compact)" \
  || fail "definitions README compact profile is not readable"
if printf '%s\n' "$readme_compact" | grep -qE 'docs/(specs|dev-contracts)/'; then
  fail "definitions README compact profile points at dev-only authority paths"
fi
grep -q '^## Controlled Vocabulary Inventory$' docs/definitions/README.md \
  || fail "definitions README missing Controlled Vocabulary Inventory section"
grep -q '^## Distribution Constraints$' docs/definitions/README.md \
  || fail "definitions README missing Distribution Constraints section"
grep -q "public/adopter checkouts" docs/definitions/README.md \
  || fail "definitions README missing public/adopter fallback guidance"
for phrase in \
  "Concept anchors" \
  "Document section keys and shapes" \
  "Workflow routes, stages, and modes"; do
  grep -q "$phrase" docs/definitions/README.md \
    || fail "definitions README missing vocabulary inventory row: $phrase"
done
ok "definitions README exposes controlled vocabulary inventory"

readme_inventory_dev_paths="$(
  awk '
    BEGIN { in_inventory=0 }
    /^## Controlled Vocabulary Inventory$/ { in_inventory=1; next }
    in_inventory && /^## / { exit }
    in_inventory && /^\| / && /docs\/(specs|dev-contracts)\// { print }
  ' docs/definitions/README.md
)"
[ -z "$readme_inventory_dev_paths" ] \
  || fail "definitions README inventory rows point at dev-only authority paths: $readme_inventory_dev_paths"
grep -q '^## Arboretum-Dev Supplemental Authorities$' docs/definitions/README.md \
  || fail "definitions README missing dev supplemental authority section"
grep -q 'not part of the compact profile' docs/definitions/README.md \
  || fail "definitions README must keep dev supplements outside compact profile"
ok "definitions README compact inventory is public/adopter safe"

grep -q "public/adopter checkouts" "$CATALOG" \
  || fail "concept catalog missing public/adopter fallback constraint"
grep -q "public fallback" "$CATALOG" \
  || fail "concept catalog rows do not name public fallback surfaces"
missing_public_fallback="$(
  awk '
    BEGIN { in_catalog=0 }
    /^## Catalog$/ { in_catalog=1; next }
    in_catalog && /^## / { exit }
    in_catalog && /^\| [a-z0-9][a-z0-9-]+ / &&
      /`docs\/specs\// &&
      $0 !~ /public fallback/ &&
      $0 !~ /public\/adopter checkouts should treat/ {
        print
      }
  ' "$CATALOG"
)"
[ -z "$missing_public_fallback" ] \
  || fail "concept catalog rows cite dev-only specs without public fallback guidance: $missing_public_fallback"
ok "concept catalog is public/adopter fallback aware"

for spec in \
  docs/specs/document-taxonomy.spec.md \
  docs/specs/roadmap.spec.md \
  docs/specs/intake-report.spec.md \
  docs/specs/workflow-unification.spec.md; do
  grep -q 'definitions/concept-catalog.md@v2' "$spec" \
    || fail "$spec does not cite definitions/concept-catalog.md@v2"
done
ok "concept-heavy specs cite the catalog definition"

python3 - "$CATALOG" <<'PY' || fail "catalog owner/canonical surfaces must exist"
import re
import sys
from pathlib import Path

catalog = Path(sys.argv[1])
root = Path.cwd()
known_external = {"external"}
missing = []

rows = []
in_catalog = False
for line in catalog.read_text().splitlines():
    if line == "## Catalog":
        in_catalog = True
        continue
    if in_catalog and line.startswith("## "):
        break
    if in_catalog and re.match(r"^\| [a-z0-9][a-z0-9-]+ ", line):
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if parts and parts[0] != "---":
            rows.append(parts)

def authority_path(raw):
    code_spans = re.findall(r"`([^`]+)`", raw)
    value = code_spans[0] if code_spans else raw
    token = value.split()[0] if value.split() else ""
    if not token or token.startswith("/") or ".." in Path(token).parts:
        return None
    looks_like_path = "/" in token or token.startswith(".") or Path(token).suffix
    if not looks_like_path:
        return None
    return root / token

if authority_path("`docs/templates/README.md` section") != root / "docs/templates/README.md":
    missing.append("self-test: owner authority path parsing failed")
if authority_path("roadmap") is not None:
    missing.append("self-test: spec slug should not be parsed as an authority path")
if authority_path("../outside.md") is not None:
    missing.append("self-test: parent traversal should not be parsed as an authority path")

for concept_id, _meaning, owner, canonical, *_rest in rows:
    owner_path = root / "docs" / "specs" / f"{owner}.spec.md"
    owner_authority = authority_path(owner)
    if owner in known_external:
        pass
    elif owner_path.exists():
        pass
    elif owner_authority is not None and owner_authority.exists():
        pass
    else:
        missing.append(f"{concept_id}: owner authority missing: {owner}")
    for raw in re.findall(r"`([^`]+)`", canonical):
        path = raw.split()[0]
        if path.startswith(("docs/", "skills/", "scripts/", "workflows/", ".github/", "dev-tools/")):
            if not (root / path).exists():
                missing.append(f"{concept_id}: canonical path missing: {path}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
PY
ok "catalog owner and canonical surfaces exist"

grep -q 'docs/definitions/concept-catalog.md' docs/templates/README.md \
  || fail "taxonomy README does not point readers at the concept catalog"
ok "taxonomy entry point points to the catalog"

if grep -qiE 'trace links.*implemented|resolver tooling.*implemented' "$CATALOG"; then
  fail "catalog must not claim deferred Trace Links or Resolver Tooling are implemented"
fi
ok "deferred slices remain deferred"

echo "concept catalog smoke: ALL PASS"
