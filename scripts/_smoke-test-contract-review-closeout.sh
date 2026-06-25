#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="$ROOT/docs/contracts/review-closeout.contract.md"
HELPER="$ROOT/scripts/post-review-closeout.sh"
SKILL="$ROOT/skills/review-closeout/SKILL.md"
LAND="$ROOT/skills/land/SKILL.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }

[ -f "$CONTRACT" ] || note "review-closeout contract should exist"
[ -f "$HELPER" ] || note "post-review-closeout helper should exist"
[ -f "$SKILL" ] || note "review-closeout skill should exist"
[ -f "$LAND" ] || note "land skill should exist"

if [ -f "$CONTRACT" ]; then
  grep -q "scripts/post-review-closeout.sh" "$CONTRACT" || note "contract should own post-review-closeout.sh"
  grep -q "post-review-closeout.sh <pr> \\[--dry-run\\]" "$CONTRACT" || note "contract should document invocation"
  grep -q "resolveReviewThread" "$CONTRACT" || note "contract should document GraphQL thread resolution"
  grep -q 'comments/\$COMMENT_ID/replies' "$CONTRACT" || note "contract should document per-thread reply endpoint"
  grep -q "closeout.json" "$CONTRACT" || note "contract should document closeout ledger"
fi

if [ -f "$HELPER" ]; then
  grep -q "validate-review-dispositions.sh" "$HELPER" || note "helper should validate dispositions before closeout"
  grep -q "merge-base --is-ancestor" "$HELPER" || note "helper should verify cited commits are reachable"
  grep -q "gh pr view" "$HELPER" || note "helper should verify provider PR state"
  grep -q "resolveReviewThread" "$HELPER" || note "helper should resolve GraphQL review threads"
  grep -q "gh\", \"pr\", \"comment\"" "$HELPER" || note "helper should post a top-level summary comment"
fi

if [ -f "$SKILL" ]; then
  grep -q "Skill arboretum:receive-review" "$SKILL" || note "skill should invoke receive-review"
  grep -q "validate-review-dispositions.sh <pr>" "$SKILL" || note "skill should validate dispositions"
  grep -q "post-review-closeout.sh <pr> --dry-run" "$SKILL" || note "skill should dry-run closeout first"
  grep -q "remaining_open" "$SKILL" || note "skill should report remaining_open"
fi

if [ -f "$LAND" ]; then
  python3 - "$LAND" <<'PY' || note "land prose should preserve collect/evaluate/fix/safety/closeout/re-request order"
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
needles = [
    "collect-review.sh <N>",
    "Skill arboretum:review-evaluate <N>",
    "fixes.json",
    "head/readiness safety check",
    "Skill arboretum:review-closeout <N>",
    "request-review.sh <N> --re-request",
]
positions = []
for needle in needles:
    pos = text.find(needle)
    if pos < 0:
        raise SystemExit(f"missing {needle}")
    positions.append(pos)
if positions != sorted(positions):
    raise SystemExit("order drift")
PY
  grep -q "remaining_open" "$LAND" || note "land should gate merge-ready on remaining_open"
  grep -q -- "--unanswered" "$LAND" || note "land should gate merge-ready on collect-review --unanswered"
fi

[ "$fail" -eq 0 ] && echo "PASS: contract review-closeout" || exit 1
