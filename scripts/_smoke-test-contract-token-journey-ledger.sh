#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Contract test for docs/contracts/token-journey-ledger.contract.md (TJL-1, TJL-5).
# The linchpin: the ledger tree-builder must reconcile with the transcript
# tree-builder on a no-subagent fixture — the enforcement that keeps the push
# path honest and the audit fallback meaningful (slice-1 DS1.4 / "verify what
# you advocate"). Picked up automatically by ci-checks.sh's smoke-test loop.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }
STATE="$(mktemp -d)"; export ARBORETUM_STATE_DIR="$STATE"
trap 'rm -rf "$STATE"' EXIT
fail=0; pass(){ echo "PASS: $1"; }; fc(){ echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# No-subagent fixture. Stage transitions are driven by stage-skill invocations
# so transcript-inferred stage == ledger-inferred stage (DS1.4 coincident
# fixture). The message carrying a Skill use bills to the NEW stage in both
# builders (update-before-count ordering is identical).
tx="$STATE/tx.jsonl"
python3 - "$tx" <<'PY'
import json,sys
def use(name,**inp): return [{"type":"tool_use","id":name+"_id","name":name,"input":inp}]
U=lambda i,o,cr,cw: {"input_tokens":i,"output_tokens":o,"cache_read_input_tokens":cr,"cache_creation_input_tokens":cw}
def m(uuid,mid,content,usage,ts): return {"uuid":uuid,"timestamp":ts,"message":{"id":mid,"model":"claude-opus-4-8","content":content,"usage":usage}}
rows=[
 m("a1","m1",use("Skill",skill="design"),U(100,50,1000,200),"2026-06-10T10:00:00Z"),
 m("a2","m2",[{"type":"text","text":"x"}],U(80,40,1500,0),"2026-06-10T10:01:00Z"),
 m("a3","m3",use("Skill",skill="build"),U(120,60,1800,300),"2026-06-10T10:02:00Z"),
 m("a4","m4",use("Skill",skill="superpowers:executing-plans"),U(90,30,2000,0),"2026-06-10T10:03:00Z"),
 m("a5","m5",[{"type":"text","text":"y"}],U(70,20,2200,0),"2026-06-10T10:04:00Z"),
 # One message spanning two priced lines sharing message.id "m6" (distinct
 # uuids). Both builders must dedup on mid → count once; if either reverts to
 # uuid-dedup the trees diverge here and TJL-5 fails.
 m("a6","m6",[{"type":"text","text":"z"}],U(60,15,2300,0),"2026-06-10T10:05:00Z"),
 m("a7","m6",[{"type":"text","text":"z"}],U(60,15,2300,0),"2026-06-10T10:06:00Z"),
]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY

# Transcript tree (audit path)
tj="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$tx" --format json --stdout 2>/dev/null)"
# Ledger tree (push path): capture (no --stage → inferred, coincident) then render
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/token-journey-ledger.sh"
ledger="$STATE/l.jsonl"
journey_ledger_capture "$tx" "$ledger"
lj="$(bash "$ROOT/scripts/render-ledger-journey.sh" --ledger "$ledger" --format json --stdout 2>/dev/null)"

# TJL-1 schema keys
r1="$(head -1 "$ledger")"
ok=1; for k in uuid mid ts model stage skill billed; do jq -e "has(\"$k\")" <<<"$r1" >/dev/null || ok=0; done
[ "$ok" = 1 ] && pass TJL-1 || fc TJL-1 "row=$r1"

# TJL-5 reconciliation: compare sorted (stage,skill,context,operation,turns)
# tuples, rounded to the milli-dollar to absorb float noise.
norm() { jq -S '[.stages[] | .stage as $s | .skills[] | {stage:$s, skill:.label, ctx:(.context*1000|round), op:(.operation*1000|round), n:.turns}] | sort'; }
a="$(printf '%s' "$tj" | norm)"; b="$(printf '%s' "$lj" | norm)"
if [ "$a" = "$b" ]; then
  pass "TJL-5 (ledger-tree == transcript-tree)"
else
  fc "TJL-5 (reconciliation)" "$(diff <(echo "$a") <(echo "$b") | head -40)"
fi

# TJL-6 consumer-side scrub: a ledger row whose stage/skill carries an embedded
# control char must render a control-char-free report + stdout (defense in depth
# at the render consumer, not just the writer).
cled="$STATE/ctrl.jsonl"
python3 - "$cled" <<'PY'
import json,sys
# ESC (\x1b) + BEL (\x07) embedded in stage and skill.
row={"uuid":"c1","mid":"mc1","ts":"2026-06-10T12:00:00Z","model":"claude-opus-4-8",
     "stage":"bui[31mld","skill":"someskill",
     "billed":{"input":100,"output":50,"cache_read":1000,"cache_write":0}}
open(sys.argv[1],"w").write(json.dumps(row)+"\n")
PY
cout="$(bash "$ROOT/scripts/render-ledger-journey.sh" --ledger "$cled" --stdout 2>/dev/null)"
if printf '%s' "$cout" | LC_ALL=C grep -q "$(printf '\033')" || printf '%s' "$cout" | LC_ALL=C grep -q "$(printf '\007')"; then
  fc "TJL-6 (consumer scrub)" "control char survived into rendered output"
else
  pass "TJL-6 (consumer scrub)"
fi

[ "$fail" = 0 ] && echo "token-journey-ledger contract: ALL PASS" || exit 1
