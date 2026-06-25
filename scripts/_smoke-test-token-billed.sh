#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-billed: $1" >&2; exit 1; }
fx="$(mktemp)"; trap 'rm -f "$fx"' EXIT
# two duplicate lines for msg A (must dedupe), one for msg B with a cache_creation spike
cat > "$fx" <<'JSON'
{"message":{"id":"A","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50}}}
{"message":{"id":"A","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50}}}
{"message":{"id":"B","usage":{"input_tokens":2,"cache_creation_input_tokens":9000,"cache_read_input_tokens":1000,"output_tokens":50}}}
JSON
out="$(bash "$ROOT/scripts/read-session-billed.sh" --transcript "$fx")"
# cache_read total must be 2000 (A counted once + B), NOT 3000 (A double-counted)
grep -q 'cache_read[^0-9]*2000' <<<"$out" || fail "did not dedupe by message id (expected 2000)"
grep -qiE 'bust|spike|cache_creation' <<<"$out" || fail "no cache-health/bust signal"
echo "PASS token-billed"
