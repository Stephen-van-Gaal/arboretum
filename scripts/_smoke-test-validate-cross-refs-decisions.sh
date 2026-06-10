#!/usr/bin/env bash
# owner: project-infrastructure
# Decisions Status/supersession-link validation (#682). Greps for the check's
# own warning messages so it is robust to unrelated cross-ref warnings.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/validate-cross-refs.sh"
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/docs/specs"
: > "$FIX/docs/REGISTER.md"; : > "$FIX/contracts.yaml"
fail=0; pass(){ echo "PASS: $1"; }; fc(){ echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

mkspec() { cat > "$FIX/docs/specs/$1.spec.md"; }

# DEC-1: valid statuses + resolving supersession link -> no decision warning for D1/D2
mkspec dec_ok <<'EOF'
# owner: dec_ok
## Decisions
| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|----|----|----|----|
| D1 | a | superseded→D2 | seam | x | y | 2026-06-09 | s |
| D2 | b | active | seam | x | y | 2026-06-09 | s |
EOF
out="$("$PROBE" "$FIX" 2>&1)"
if echo "$out" | grep -qiE "decision D[12] "; then fc "DEC-1 valid passes" "$out"; else pass "DEC-1 valid passes"; fi
rm "$FIX/docs/specs/dec_ok.spec.md"

# DEC-2: dangling supersession link -> warning naming D9, rc=1
mkspec dec_dangling <<'EOF'
# owner: dec_dangling
## Decisions
| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|----|----|----|----|
| D1 | a | superseded→D9 | seam | x | y | 2026-06-09 | s |
EOF
out="$("$PROBE" "$FIX" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "D9"; then pass "DEC-2 dangling link flagged"; else fc "DEC-2 dangling link flagged" "$out"; fi
rm "$FIX/docs/specs/dec_dangling.spec.md"

# DEC-3: invalid status value -> warning mentioning status, rc=1
mkspec dec_badstatus <<'EOF'
# owner: dec_badstatus
## Decisions
| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|----|----|----|----|
| D1 | a | done | seam | x | y | 2026-06-09 | s |
EOF
out="$("$PROBE" "$FIX" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qi "status"; then pass "DEC-3 bad status flagged"; else fc "DEC-3 bad status flagged" "$out"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS: validate-cross-refs decisions" || exit 1
