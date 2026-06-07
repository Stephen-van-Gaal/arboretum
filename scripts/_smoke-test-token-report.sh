#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-report: $1" >&2; exit 1; }
b="$(mktemp)"; a="$(mktemp)"; trap 'rm -f "$b" "$a"' EXIT
printf '{"contributor":"reads","est_tokens":1000}\n{"contributor":"runtime","est_tokens":800}\n' > "$b"
printf '{"contributor":"reads","est_tokens":400}\n{"contributor":"runtime","est_tokens":850}\n'  > "$a"
out="$(bash "$ROOT/scripts/token-report.sh" compare "$b" "$a")"
grep -qE 'reads[^0-9-]*-600'  <<<"$out" || fail "reads delta should be -600"
grep -qE 'runtime[^0-9-]*\+?50' <<<"$out" || fail "runtime delta should be +50 (inflation caught)"

tr="$(mktemp)"; trap 'rm -f "$b" "$a" "$tr"' EXIT
# 8 prior runs at reads-share ~0.25, then a spike run at ~0.75, all (wf=/build,stage=build)
{ for i in $(seq 1 8); do
    printf '{"run_id":"r%s","workflow":"/build","stage":"build","contributor":"reads","est_tokens":250}\n' "$i"
    printf '{"run_id":"r%s","workflow":"/build","stage":"build","contributor":"runtime","est_tokens":750}\n' "$i"
  done
  printf '{"run_id":"r9","workflow":"/build","stage":"build","contributor":"reads","est_tokens":750}\n'
  printf '{"run_id":"r9","workflow":"/build","stage":"build","contributor":"runtime","est_tokens":250}\n'
} > "$tr"
out="$(bash "$ROOT/scripts/token-report.sh" trend --ledger "$tr")"
grep -qiE 'reads.*(breach|up|exceed)' <<<"$out" || fail "trend did not flag reads-share breach"
echo "PASS token-report"
