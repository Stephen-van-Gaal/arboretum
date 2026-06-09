#!/usr/bin/env bash
# owner: document-taxonomy
# Asserts the real governed-spec content model (#671): the spec.md template,
# the document-shapes catalog, and the concept-catalog carry the mandatory-core
# invariants, the two optional sections, schema-driven authorship, the
# areas: split-gate, the seam-escalation rule, and the new vocabulary anchors.
# Enforcement floor only — full validators are #685.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/docs/templates/spec.md"
SHAPES="$ROOT/docs/templates/document-shapes.yaml"
CATALOG="$ROOT/docs/definitions/concept-catalog.md"

fail=0
assert() { # <file> <pattern> <label>
  if grep -qiF -- "$2" "$1"; then echo "PASS: $3"; else echo "FAIL: $3 (missing: $2 in ${1#$ROOT/})" >&2; fail=1; fi
}

# governed-spec shape block only (so a design-spec record can't false-positive).
gs_block() { awk '/^  governed-spec:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$SHAPES"; }
assert_gs() { # <pattern> <label>
  if gs_block | grep -qiF -- "$1"; then echo "PASS: $2"; else echo "FAIL: $2 (missing in governed-spec block: $1)" >&2; fail=1; fi
}

# --- spec.md template (Task 1) ---
assert "$SPEC" "implementable without opening" "spec: self-contained Behaviour invariant"
assert "$SPEC" "provenance only" "spec: provenance-only/never-substitution rule"
assert "$SPEC" "## Quality Attributes" "spec: Quality Attributes optional section"
assert "$SPEC" "## Customer Experience" "spec: Customer Experience optional section"
assert "$SPEC" "Sections changed" "spec: Design record upgraded to changelog"
assert "$SPEC" "inbound seam" "spec: Requires/Provides seam-escalation comment"
assert "$SPEC" "split-assessment" "spec: areas: frontmatter example present"

# --- document-shapes.yaml governed-spec block (Task 2) ---
assert_gs "authorship: append-auto" "shapes: authorship field present (governed-spec)"
assert_gs "key: quality-attributes" "shapes: quality-attributes record (governed-spec)"
assert_gs "key: customer-experience" "shapes: customer-experience record (governed-spec)"

# --- concept-catalog.md vocabulary (Task 4) ---
assert "$CATALOG" "promotion-contract" "catalog: promotion-contract anchor"
assert "$CATALOG" "spec-area" "catalog: spec-area anchor"
assert "$CATALOG" "quality-attributes" "catalog: quality-attributes anchor"
assert "$CATALOG" "consumes" "catalog: Requires/Provides<->consumes/produces mapping"

# --- promotion contract (Task 5) ---
CONTRACT="$ROOT/docs/contracts/promotion.contract.md"
assert "$CONTRACT" "provenance only" "contract: provenance-only invariant"
assert "$CONTRACT" "never substitution" "contract: never-substitution"
assert "$CONTRACT" "Alternatives" "contract: Decisions carry Alternatives + Rationale"
assert "$CONTRACT" "self-contained" "contract: self-contained Behaviour required"
assert "$CONTRACT" "#686" "contract: names #686 as when/how owner"

# --- worked-example fixture satisfies the model (Task 8 / #685 seed) ---
FIXTURE="$ROOT/tests/fixtures/spec-content-model/idealized-component-spec.example.md"
[ -f "$FIXTURE" ] && echo "PASS: fixture present" || { echo "FAIL: fixture missing" >&2; fail=1; }
if [ -f "$FIXTURE" ]; then
  assert "$FIXTURE" "ILLUSTRATIVE FIXTURE" "fixture: marked illustrative (not a live spec)"
  assert "$FIXTURE" "split-assessment" "fixture: areas split-assessment present"
  assert "$FIXTURE" "## Requires" "fixture: Requires (inbound seam) present"
  assert "$FIXTURE" "Alternatives Considered" "fixture: Decisions carry Alternatives+Rationale"
  assert "$FIXTURE" "Sections changed" "fixture: Design record changelog present"
fi

[ "$fail" = 0 ] && echo "spec content-model: ALL PASS" || exit 1
