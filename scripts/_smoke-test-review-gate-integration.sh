#!/usr/bin/env bash
# owner: review-stage
# _smoke-test-review-gate-integration.sh — assert the data the B4 driver consumes:
# the registry-selected applicable set (review-registry-filter) and which of those
# lanes are skip-candidates (review-dispatch --verdicts). The driver's confirm-on-skip
# decision is built from exactly this pair.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="$(git rev-parse --show-toplevel)/reviewers.yml"
fail_count=0
note() { echo "FAIL: $1" >&2; ((fail_count++)) || true; }

# selected applicable lane ids (comma-wrapped for membership tests). The registry may
# also select runtime reviewers (e.g. codex) — the gate classifies only the three skill
# lanes, so we assert membership, never exact set equality.
selected() { printf ',%s,' "$(printf '%s\n' "$@" \
  | bash "$SCRIPT_DIR/review-registry-filter.sh" "$REG" --altitude finish --artifact diff --files-from - \
  | jq -r '.id' | paste -sd, -)" ; }
# skip-candidate skill-lane ids per verdicts (relevant == false), comma-wrapped.
skips() { printf ',%s,' "$(printf '%s\n' "$@" \
  | bash "$SCRIPT_DIR/review-dispatch.sh" --verdicts --files-from - \
  | jq -r '.lanes | to_entries[] | select(.value.relevant==false) | .key' | sort | paste -sd, -)" ; }
has() { case "$1" in *",$2,"*) return 0 ;; *) return 1 ;; esac }

# prose-only README change: general-security selected AND a skip-candidate; correctness not selected.
has "$(selected README.md docs/x.md)" general-security || note "prose: general-security not selected"
has "$(skips README.md docs/x.md)"    general-security || note "prose: general-security not a skip-candidate"
has "$(selected README.md docs/x.md)" correctness      && note "prose: correctness wrongly selected"

# code change: general-security + correctness selected; neither is a skip-candidate.
has "$(selected src/app.ts)" general-security || note "code: general-security not selected"
has "$(selected src/app.ts)" correctness      || note "code: correctness not selected"
has "$(skips src/app.ts)"    general-security && note "code: general-security wrongly a skip-candidate"
has "$(skips src/app.ts)"    correctness       && note "code: correctness wrongly a skip-candidate"

# config-only (settings.json): general-security selected AND relevant (D1 guard), not a skip.
has "$(selected .claude/settings.json)" general-security || note "config: general-security not selected"
has "$(skips .claude/settings.json)"    general-security && note "config: general-security wrongly a skip-candidate"

if [ "$fail_count" -gt 0 ]; then echo "FAIL: $fail_count case(s)" >&2; exit 1; fi
echo "PASS: review-gate integration — selected set ∩ skip-candidates"
