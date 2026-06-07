#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-busts: $1" >&2; exit 1; }
fx="$(mktemp)"; trap 'rm -f "$fx"' EXIT
cat > "$fx" <<'JSON'
{"timestamp":"2026-06-06T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":80000,"cache_read_input_tokens":0,"output_tokens":10}}}
{"timestamp":"2026-06-06T10:00:30Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":500,"cache_read_input_tokens":80000,"output_tokens":10}}}
{"timestamp":"2026-06-06T10:01:00Z","message":{"id":"m3","model":"claude-sonnet-4-6","usage":{"input_tokens":2,"cache_creation_input_tokens":80000,"cache_read_input_tokens":0,"output_tokens":10}}}
{"timestamp":"2026-06-06T10:01:30Z","isCompactSummary":true,"message":{"role":"user"}}
{"timestamp":"2026-06-06T10:01:40Z","message":{"id":"m4","model":"claude-sonnet-4-6","usage":{"input_tokens":2,"cache_creation_input_tokens":12000,"cache_read_input_tokens":0,"output_tokens":10}}}
JSON
out="$(bash "$ROOT/scripts/token-report.sh" busts --transcript "$fx")"
grep -qiE 'm3|model switch' <<<"$out" || fail "did not capture the model-switch bust"
grep -qi 'compaction' <<<"$out"       || fail "did not classify the compaction boundary"
# the compaction-adjacent deficit must NOT be counted as avoidable waste
grep -qiE 'compaction[^$]*(expected|excluded|not counted)' <<<"$out" || fail "compaction not excluded from waste"
echo "PASS token-busts"
