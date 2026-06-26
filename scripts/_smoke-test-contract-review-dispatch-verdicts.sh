#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-contract-review-dispatch-verdicts.sh — assert review-dispatch.sh
# --verdicts emits the documented JSON shape: three lanes, each {relevant:bool,
# reason:string}, plus any_relevant = OR of the three booleans.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="$SCRIPT_DIR/review-dispatch.sh"
fail_count=0
note() { echo "FAIL: $1" >&2; ((fail_count++)) || true; }

json=$(printf '%s\n' "src/app.ts" "README.md" | bash "$PLAN" --verdicts --files-from -)

# Shape: exactly the three lanes, each with boolean relevant + string reason.
for lane in ai-surface general-security correctness; do
  [ "$(jq -r ".lanes[\"$lane\"].relevant | type" <<<"$json")" = "boolean" ] || note "$lane.relevant not boolean"
  [ "$(jq -r ".lanes[\"$lane\"].reason | type"   <<<"$json")" = "string"  ] || note "$lane.reason not string"
done
[ "$(jq -r '.lanes | keys | sort | join(",")' <<<"$json")" = "ai-surface,correctness,general-security" ] \
  || note "lanes key set wrong"

# Invariant: any_relevant == OR of the three relevant booleans.
or_val=$(jq -r '([.lanes[].relevant] | any)' <<<"$json")
[ "$(jq -r '.any_relevant' <<<"$json")" = "$or_val" ] || note "any_relevant != OR of lanes"
[ "$(jq -r '.any_relevant | type' <<<"$json")" = "boolean" ] || note "any_relevant not boolean"

if [ "$fail_count" -gt 0 ]; then echo "FAIL: $fail_count case(s)" >&2; exit 1; fi
echo "PASS: review-dispatch --verdicts contract — shape + any_relevant invariant"
