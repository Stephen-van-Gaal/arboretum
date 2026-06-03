#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-validate-cross-refs.sh — Contract test for
# docs/contracts/validate-cross-refs.contract.md. Asserts VCR-1..VCR-2
# against scripts/validate-cross-refs.sh. VCR-1 runs the validator
# against the live repo root (must be CONSISTENT). VCR-2 builds a temp
# project-dir fixture with one well-formed spec carrying both requires
# and provides pins plus one malformed dep entry, then asserts the
# expected ✗-warning + non-zero exit. Picked up automatically by
# ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-cross-refs.sh"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# VCR-1 — live repo root is CONSISTENT (exit 0, summary + Check-4 green)
out=$(bash "$VALIDATOR" "$ROOT" 2>&1); rc=$?
if [ "$rc" = 0 ] \
  && echo "$out" | grep -q "CONSISTENT: All cross-reference checks passed." \
  && echo "$out" | grep -q "All frontmatter dep notations are well-formed"; then
  pass VCR-1
else
  fail_case VCR-1 "rc=$rc out=$out"
fi

# VCR-2 — temp fixture with a malformed dep entry → exit 1, distinct ✗ warning.
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/docs/definitions"

for definition in input output; do
  printf '# %s\n\n## Version\nv1\n' "$definition" > "$FIXTURE/docs/definitions/${definition}.md"
done

cat > "$FIXTURE/docs/specs/good.spec.md" <<'EOF'
---
name: good
status: active
owner: alice
requires:
  - definitions/input.md@v1
provides:
  - definitions/output.md@v1
---

# good

## Requires

| Definition | Version |
|---|---|
| definitions/input.md@v1 | required |

## Provides

| Definition | Version |
|---|---|
| definitions/output.md@v1 | provided |

## Notes

Line citations resolve to the base file, not a literal filename:
docs/definitions/input.md:12-24.
EOF

cat > "$FIXTURE/docs/specs/bad.spec.md" <<'EOF'
---
name: bad
status: active
owner: bob
requires:
  - definitions/unsuffixed
---

# bad

Fixture spec with one malformed (missing-.md-suffix) dep notation.
EOF

cat > "$FIXTURE/contracts.yaml" <<'EOF'
version: 1
specs:
  good:
    requires:
      definitions/input.md: v1
    provides:
      definitions/output.md: v1
EOF

out=$(bash "$VALIDATOR" "$FIXTURE" 2>&1); rc=$?
if [ "$rc" = 1 ] \
  && echo "$out" | grep -q 'bad.spec.md: requires entry "definitions/unsuffixed" looks like a path but lacks .md suffix' \
  && ! echo "$out" | grep -q 'definitions/input.md:12-24.md' \
  && ! echo "$out" | grep -q 'contracts.yaml has definitions/output.md@v1 for good but spec does not require it' \
  && echo "$out" | grep -q "ISSUES FOUND:"; then
  pass VCR-2
else
  fail_case VCR-2 "rc=$rc out=$out"
fi

[ "$fail" = 0 ] && echo "validate-cross-refs contract: ALL PASS" || exit 1
