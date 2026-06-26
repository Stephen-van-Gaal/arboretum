#!/usr/bin/env bash
# owner: document-access
# scope: plugin-only
# ci-parallel: safe
# Integration test for the schema-coupled decision-record chain (#682): a single
# fixture spec flows schema-shape → read-decisions.sh (summary/detail) →
# validate-cross-refs.sh. Per CLAUDE.md ## Schema-coupled scripts, exercise the
# whole chain, not each script in isolation (the #124 class of silent breakage).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/docs/specs"; : > "$FIX/docs/REGISTER.md"; : > "$FIX/contracts.yaml"

fail=0; pass(){ echo "PASS: $1"; }; fc(){ echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

# A ≥15-row fixture exercising active/moot/superseded + facet+area tags.
SPEC="$FIX/docs/specs/fixture.spec.md"
{
  echo "# owner: fixture"; echo; echo "## Decisions"; echo
  echo "| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |"
  echo "|----|----------|--------|------|----|----|----|----|"
  for n in $(seq 1 16); do
    st=""; [ "$n" -eq 3 ] && st="moot"; [ "$n" -eq 5 ] && st="superseded→D6"
    echo "| D$n | decision $n | $st | seam +area:retrieval | alt | why | 2026-06-09 | design |"
  done
} > "$SPEC"

# 1. read-decisions summary projects all 16 rows; D3 shows moot.
out="$(bash "$ROOT/scripts/read-decisions.sh" "$SPEC" --summary)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '·' <<<"$out")" -eq 16 ] \
   && grep -q "D3 · decision 3 · moot · seam +area:retrieval" <<<"$out"; then
  pass "chain: summary projection"; else fc "chain: summary projection" "$out"; fi

# 2. detail returns the superseded row verbatim.
out="$(bash "$ROOT/scripts/read-decisions.sh" "$SPEC" --detail D5)"
grep -q "superseded→D6" <<<"$out" && pass "chain: detail by ID" || fc "chain: detail by ID" "$out"

# 3. validation passes (D6 exists, statuses valid) — assert rc and absence of warnings.
out="$(bash "$ROOT/scripts/validate-cross-refs.sh" "$FIX" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || echo "$out" | grep -qiE "invalid Status|is superseded by missing"; then fc "chain: clean spec validates" "rc=$rc $out"; else pass "chain: clean spec validates"; fi

# 4. break the link → validation flags it (end-to-end coupling proof).
sed -i.bak 's/superseded→D6/superseded→D99/' "$SPEC"; rm -f "$SPEC.bak"
out="$(bash "$ROOT/scripts/validate-cross-refs.sh" "$FIX" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "D99"; then pass "chain: broken link caught"; else fc "chain: broken link caught" "$out"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS: decision-record chain" || exit 1
