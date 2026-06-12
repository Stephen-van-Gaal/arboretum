#!/usr/bin/env bash
# owner: token-accounting
# Integration smoke test: the Stop + SessionEnd hooks end-to-end (#721).
# Enabled path captures rows and renders an artifact; || true never blocks on a
# missing transcript; the disabled gate suppresses capture.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }
STATE="$(mktemp -d)"
export ARBORETUM_STATE_DIR="$STATE/.arboretum"   # state subtree shares the project .arboretum root
export CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$STATE"
trap 'rm -rf "$STATE"' EXIT
fail=0; pass(){ echo "PASS: $1"; }; fc(){ echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

mkdir -p "$STATE/.arboretum"
printf '{"issue":721,"stage":"/build","ts":"2026-06-10T10:00:00Z"}\n' > "$STATE/.arboretum/active-stage-cache.json"
printf 'token_journey:\n  enabled: true\n  format: md\n' > "$STATE/.arboretum.yml"

tx="$STATE/tx.jsonl"
python3 - "$tx" <<'PY'
import json,sys
U=lambda i,o,cr,cw:{"input_tokens":i,"output_tokens":o,"cache_read_input_tokens":cr,"cache_creation_input_tokens":cw}
rows=[
 {"uuid":"a1","timestamp":"2026-06-10T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","content":[{"type":"text","text":"x"}],"usage":U(100,50,1000,200)}},
 {"uuid":"a2","timestamp":"2026-06-10T10:01:00Z","message":{"id":"m2","model":"claude-opus-4-8","content":[{"type":"text","text":"y"}],"usage":U(80,40,1500,0)}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY

payload(){ printf '{"session_id":"s1","transcript_path":"%s"}' "$1"; }
led="$STATE/.arboretum/token-journey-ledger/s1.jsonl"

# ENABLED path: Stop captures
payload "$tx" | bash "$ROOT/hooks/token-journey-stop.sh"; rc=$?
[ "$rc" = 0 ] && pass "stop rc=0" || fc "stop rc" "rc=$rc"
[ -s "$led" ] && pass "ledger populated" || fc "ledger populated" "expected $led"
# stage came authoritatively from active-stage-cache.json (/build -> build)
[ "$(jq -r '.stage' "$led" | head -1)" = "build" ] && pass "authoritative stage" || fc "authoritative stage" "got $(jq -r '.stage' "$led" | head -1)"

# SessionEnd renders the artifact
payload "$tx" | bash "$ROOT/hooks/token-journey-session-end.sh"; rc=$?
[ "$rc" = 0 ] && pass "session-end rc=0" || fc "session-end rc" "rc=$rc"
ls "$STATE/.arboretum/token-journey/"*.md >/dev/null 2>&1 && pass "artifact rendered" || fc "artifact rendered"

# || true: a missing transcript never errors
payload "/nope" | bash "$ROOT/hooks/token-journey-stop.sh"; [ "$?" = 0 ] && pass "missing-tx non-blocking" || fc "missing-tx non-blocking"

# DISABLED path: no capture
rm -rf "$STATE/.arboretum/token-journey-ledger" "$STATE/.arboretum/token-journey"
printf 'token_journey:\n  enabled: false\n' > "$STATE/.arboretum.yml"
payload "$tx" | bash "$ROOT/hooks/token-journey-stop.sh"
[ ! -e "$led" ] && pass "disabled gate" || fc "disabled gate" "ledger should not exist"

# DISABLED + substring trap (Codex P3): enabled:false but output_dir contains
# the literal "enabled=true" — the exact-line gate must keep this disabled.
rm -rf "$STATE/.arboretum/token-journey-ledger"
printf 'token_journey:\n  enabled: false\n  output_dir: /tmp/x-enabled=true\n' > "$STATE/.arboretum.yml"
payload "$tx" | bash "$ROOT/hooks/token-journey-stop.sh"
[ ! -e "$led" ] && pass "enabled= exact-line gate (substring trap)" || fc "substring trap" "ledger should not exist"

# output_dir honored (Codex P2): a configured output_dir lands the SessionEnd
# artifact there, not under the default token-journey/.
rm -rf "$STATE/.arboretum/token-journey-ledger" "$STATE/.arboretum/token-journey"
custom="$STATE/custom-journey"
printf 'token_journey:\n  enabled: true\n  format: md\n  output_dir: %s\n' "$custom" > "$STATE/.arboretum.yml"
payload "$tx" | bash "$ROOT/hooks/token-journey-stop.sh"
payload "$tx" | bash "$ROOT/hooks/token-journey-session-end.sh"
ls "$custom"/*.md >/dev/null 2>&1 && pass "output_dir honored" || fc "output_dir honored" "no artifact under $custom"

[ "$fail" = 0 ] && echo "token-journey push integration: ALL PASS" || exit 1
