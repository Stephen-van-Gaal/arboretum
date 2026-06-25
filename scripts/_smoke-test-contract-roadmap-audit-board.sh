#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-roadmap-audit-board.sh — Contract test for
# docs/contracts/roadmap-audit-board.cli-contract.md. Asserts CLI-1..CLI-5
# against scripts/roadmap/audit-board.sh.
#
# audit-board.sh supports a file-driven test mode (--board-file) that
# bypasses the gh/network guards, so we drive it against an inline board
# fixture in a temp directory with no network and no gh auth.
# This pins the five-bucket ruleset, blocked-label precedence, counts
# integrity, and the unknown-arg → exit 2 invariant.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/roadmap/audit-board.sh"
[ -f "$AUDIT" ] || { echo "FAIL: $AUDIT not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# Fixture: one issue per bucket archetype, anchored to 2026-05-30.
#
#   #1 — speculative: no horizon label, updatedAt 270+ days before as-of (2025-08-01)
#   #2 — inbox:       no horizon label, createdAt within 7 days of as-of (2026-05-25)
#   #3 — well_scoped: type:feature + horizon:next, not blocked, not active
#   #4 — active:      horizon:now, updatedAt within 14 days (2026-05-20)
#   #5 — other:       blocked label (overrides everything, even horizon:now + recent)
BOARD="$TMP/board.json"
cat > "$BOARD" <<'JSON'
[
  {
    "number": 1,
    "title": "stale unlabeled issue",
    "labels": [],
    "createdAt": "2025-08-01T00:00:00Z",
    "updatedAt": "2025-08-01T00:00:00Z",
    "comments": 0,
    "milestone": null
  },
  {
    "number": 2,
    "title": "fresh inbox idea",
    "labels": [],
    "createdAt": "2026-05-25T00:00:00Z",
    "updatedAt": "2026-05-25T00:00:00Z",
    "comments": 0,
    "milestone": null
  },
  {
    "number": 3,
    "title": "well-scoped feature",
    "labels": [
      {"name": "type:feature"},
      {"name": "horizon:next"}
    ],
    "createdAt": "2026-04-15T00:00:00Z",
    "updatedAt": "2026-04-30T00:00:00Z",
    "comments": 1,
    "milestone": null
  },
  {
    "number": 4,
    "title": "active in-flight work",
    "labels": [
      {"name": "horizon:now"}
    ],
    "createdAt": "2026-05-01T00:00:00Z",
    "updatedAt": "2026-05-20T00:00:00Z",
    "comments": 2,
    "milestone": null
  },
  {
    "number": 5,
    "title": "blocked issue with horizon:now",
    "labels": [
      {"name": "horizon:now"},
      {"name": "blocked"}
    ],
    "createdAt": "2026-05-01T00:00:00Z",
    "updatedAt": "2026-05-20T00:00:00Z",
    "comments": 1,
    "milestone": null
  }
]
JSON

result=$(bash "$AUDIT" --board-file "$BOARD" --as-of 2026-05-30); rc=$?

# CLI-1 — file-driven mode produces valid JSON, exit 0, keys are issues/by_bucket/counts
if [ "$rc" = 0 ] && printf '%s\n' "$result" | jq -e 'has("issues") and has("by_bucket") and has("counts")' >/dev/null 2>&1; then
  pass CLI-1
else
  fail_case CLI-1 "rc=$rc result=[$result]"
fi

# CLI-2 — five-bucket ruleset: each archetype lands in its expected bucket
declare -A WANT
WANT[1]=speculative
WANT[2]=inbox
WANT[3]=well_scoped
WANT[4]=active
WANT[5]=other

all_pass=1
for n in 1 2 3 4 5; do
  want="${WANT[$n]}"
  got=$(printf '%s\n' "$result" | jq -r --arg n "$n" '.issues[$n] // "MISSING"')
  if [ "$got" = "$want" ]; then
    pass "CLI-2 #$n → $got"
  else
    fail_case "CLI-2 #$n" "expected $want, got $got"
    all_pass=0
  fi
done
[ "$all_pass" = 1 ] && pass "CLI-2 (all five buckets correct)" || true

# CLI-3 — blocked label takes precedence: #5 has horizon:now + recent update but
# carries blocked → must be other, not active
bucket5=$(printf '%s\n' "$result" | jq -r '.issues["5"] // "MISSING"')
if [ "$bucket5" = "other" ]; then
  pass CLI-3
else
  fail_case CLI-3 "blocked+horizon:now issue: expected other, got $bucket5"
fi

# CLI-4 — counts values sum to total issue count (5)
total=$(printf '%s\n' "$result" | jq '[.counts | to_entries[].value] | add // 0')
if [ "$total" = "5" ]; then
  pass CLI-4
else
  fail_case CLI-4 "counts sum=$total, expected 5"
fi

# CLI-5 — unknown argument → exit 2, no stdout
stdout5=$(bash "$AUDIT" --bogus 2>/dev/null); rc5=$?
if [ "$rc5" = 2 ] && [ -z "$stdout5" ]; then
  pass CLI-5
else
  fail_case CLI-5 "rc=$rc5 stdout=[$stdout5]"
fi

[ "$fail" = 0 ] && echo "roadmap-audit-board contract: ALL PASS" || { echo "roadmap-audit-board contract: FAILED" >&2; exit 1; }
