#!/usr/bin/env bash
# owner: token-accounting
# Unit smoke test for scripts/lib/token-journey-ledger.sh (TJL-1..4 minus the
# reconciliation linchpin, which lives in the contract test).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-journey-ledger: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

STATE="$(mktemp -d)"; export ARBORETUM_STATE_DIR="$STATE"
trap 'rm -rf "$STATE"' EXIT
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/token-journey-ledger.sh"

# Fixture transcript: 2 priced assistant messages. The first carries a Skill
# tool_use (sets skill) and a cache_creation block; the second embeds an ASCII
# control char (chr(2)) in the model field to exercise the scrub.
tx="$STATE/tx.jsonl"
python3 - "$tx" <<'PY'
import json,sys
rows=[
 {"uuid":"u1","timestamp":"2026-06-10T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8",
   "content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"superpowers:executing-plans"}}],
   "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300}}},
 {"uuid":"u2","timestamp":"2026-06-10T10:01:00Z","message":{"id":"m2","model":"claude-opus-4-8"+chr(2),
   "content":[{"type":"text","text":"ok"}],
   "usage":{"input_tokens":80,"output_tokens":40,"cache_read_input_tokens":2500,"cache_creation_input_tokens":0}}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY

ledger="$STATE/ledger.jsonl"
journey_ledger_capture "$tx" "$ledger" --stage build

# TJL-1 schema keys
row1="$(head -1 "$ledger")"
for k in uuid mid ts model stage skill billed; do
  jq -e "has(\"$k\")" <<<"$row1" >/dev/null || fail "schema missing key: $k"
done
for k in input output cache_read cache_write; do
  jq -e ".billed|has(\"$k\")" <<<"$row1" >/dev/null || fail "billed missing key: $k"
done
# TJL-2 cache_write mapping (cache_creation_input_tokens=300)
[ "$(jq -r '.billed.cache_write' <<<"$row1")" = 300 ] || fail "cache_write mapping"
# skill inferred from the Skill tool_use
[ "$(jq -r '.skill' <<<"$row1")" = "superpowers:executing-plans" ] || fail "skill inference"
# stage from --stage override
[ "$(jq -r '.stage' <<<"$row1")" = build ] || fail "stage override"

# TJL-3 control-char scrub: row 2's model had an embedded chr(2); stored scrubbed.
row2="$(sed -n '2p' "$ledger")"
[ "$(jq -r '.model' <<<"$row2")" = "claude-opus-4-8" ] || fail "control char not scrubbed from model"

# TJL-4 watermark resume: re-capture → no new rows, no dup uuids
n1="$(wc -l < "$ledger")"
journey_ledger_capture "$tx" "$ledger" --stage build
n2="$(wc -l < "$ledger")"
[ "$n1" = "$n2" ] || fail "watermark resume re-appended ($n1 -> $n2)"
[ -z "$(jq -r .uuid "$ledger" | sort | uniq -d)" ] || fail "duplicate uuid after re-capture"

# TJL-4 (mid-dedup): a real assistant message spans many transcript lines sharing
# one message.id but distinct uuids, all priced. The ledger must emit ONE row for
# that id — matching journey_render.process — else the reconciliation breaks.
tx2="$STATE/tx2.jsonl"
python3 - "$tx2" <<'PY'
import json,sys
# 3 lines, same message id "mShared", distinct uuids, all carrying usage.
rows=[{"uuid":f"v{i}","timestamp":"2026-06-10T11:0%d:00Z"%i,
       "message":{"id":"mShared","model":"claude-opus-4-8","content":[{"type":"text","text":"x"}],
       "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}
      for i in range(3)]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY
ledger2="$STATE/ledger2.jsonl"
journey_ledger_capture "$tx2" "$ledger2" --stage build
rows2="$(wc -l < "$ledger2" | tr -d ' ')"
[ "$rows2" = 1 ] || fail "mid-dedup: 3 lines sharing one message.id produced $rows2 rows (expected 1)"
[ "$(jq -r .mid "$ledger2" | head -1)" = "mShared" ] || fail "mid-dedup: row not keyed by message id"

echo "PASS token-journey-ledger"
