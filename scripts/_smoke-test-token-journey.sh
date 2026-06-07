#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-journey: $1" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
main="$work/sess-abc.jsonl"

# Synthetic main transcript: one /design Skill turn, then a brainstorming Skill
# turn, then a priced model turn under each. cache_read=context, input/cache_creation/output=operation.
cat > "$main" <<'JSONL'
{"uuid":"u1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"m1","model":"claude-opus-4","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"arboretum:design"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"uuid":"u2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"m2","model":"claude-opus-4","content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"superpowers:brainstorming"}}],"usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000,"output_tokens":100}}}
JSONL

out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --stdout)"
grep -qiE 'STAGE +design' <<<"$out" || fail "design stage not attributed"
grep -qiE 'brainstorming' <<<"$out" || fail "brainstorming skill not attributed under design"
# Cost math (opus rates: input 5, output 25, cache_write 6.25, cache_read 0.50 per 1M):
#   m1 (design):       ctx=0                op=(100*5 + 50*25)/1e6  = 0.00175
#   m2 (brainstorming): ctx=10000*0.50/1e6=0.005  op=(200*5 + 100*25)/1e6 = 0.00350
#   total = 0.005 + 0.00525 = 0.01025 -> renders 0.010 at 3dp
grep -qiE 'total\$?=?0\.010' <<<"$out" || fail "total cost math wrong (expected 0.010)"

# --- subagent fixpoint: 2-level nesting (grandchild attributes to design) ---
mkdir -p "$work/sess-abc/subagents"
# child agent spawned from main turn u2 (under design/brainstorming)
cat > "$work/sess-abc/subagents/agent-child.jsonl" <<'JSONL'
{"uuid":"c1","parentUuid":"u2","attributionAgent":"general-purpose","message":{"id":"cm1","model":"claude-opus-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}}}
JSONL
# grandchild agent spawned from child turn c1 (must still resolve to design via fixpoint)
cat > "$work/sess-abc/subagents/agent-grand.jsonl" <<'JSONL'
{"uuid":"g1","parentUuid":"c1","attributionAgent":"Explore","message":{"id":"gm1","model":"claude-haiku-4","usage":{"input_tokens":400,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
JSONL
out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --stdout)"
grep -qiE 'Agent:general-purpose' <<<"$out" || fail "child subagent not joined"
grep -qiE 'Agent:Explore'         <<<"$out" || fail "grandchild subagent not joined (fixpoint failed)"
# both subagents must land under the design stage block, not (pre-workflow)
grep -qiE 'STAGE +design' <<<"$out" || fail "subagents not attributed to design stage"

# broken chain → warn, not crash
mkdir -p "$work/sess-broken/subagents"
echo '{"a":1}' > "$work/sess-broken.jsonl"
cat > "$work/sess-broken/subagents/agent-orphan.jsonl" <<'JSONL'
{"uuid":"o1","parentUuid":"does-not-exist","message":{"id":"om1","model":"claude-opus-4","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
JSONL
warn="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$work/sess-broken.jsonl" --stdout 2>&1 >/dev/null)"
grep -qiE 'warn.*unresolved' <<<"$warn" || fail "broken parentUuid should warn on stderr"

# --- intake diagnostic: a big early Bash read should top carry-burden ---
big="$work/sess-intake.jsonl"
cat > "$big" <<'JSONL'
{"uuid":"i1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"im1","model":"claude-opus-4","content":[{"type":"tool_use","id":"tb","name":"Bash","input":{"command":"cat huge.log"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"uuid":"i2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"im2","content":[{"type":"tool_result","tool_use_id":"tb","content":"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}]}}
{"uuid":"i3","timestamp":"2026-06-07T10:02:00Z","message":{"id":"im3","model":"claude-opus-4","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
JSONL
out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$big" --stdout)"
grep -qiE 'CONTEXT INTAKE' <<<"$out" || fail "intake diagnostic section missing"
grep -qiE 'Bash cat huge.log' <<<"$out" || fail "Bash intake source not labelled"

# --- persistence + idempotency: re-run same transcript = same path + same bytes ---
outdir="$work/journeys"
# Path is carried on the pointer line `token-journey report: <path>` (D8 inversion).
p1="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$outdir" --descriptor "issue-627" | sed -n 's/^token-journey report: //p')"
[ -f "$p1" ] || fail "report artifact not written ($p1)"
case "$p1" in *"-issue-627.md") :;; *) fail "filename should end with descriptor: $p1";; esac
case "$p1" in *"2026-06-07T100100"*) :;; *) fail "timestamp should come from transcript last msg: $p1";; esac
sum1="$(shasum "$p1" | awk '{print $1}')"
p2="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$outdir" --descriptor "issue-627" | sed -n 's/^token-journey report: //p')"
[ "$p1" = "$p2" ] || fail "non-idempotent filename ($p1 != $p2)"
[ "$sum1" = "$(shasum "$p2" | awk '{print $1}')" ] || fail "non-idempotent bytes"

# --- output inversion: default run must NOT print the per-stage table to stdout ---
default_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j2" --descriptor "issue-627")"
grep -qiE 'STAGE +design' <<<"$default_out" && fail "default run leaked report body into stdout (D8 violation)"
grep -qiE 'token-journey report:' <<<"$default_out" || fail "default run should print a pointer line"
grep -qiE 'total\$' <<<"$default_out" || fail "pointer should include headline total\$"
# --stdout still dumps the full body
full_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j3" --descriptor "issue-627" --stdout)"
grep -qiE 'STAGE +design' <<<"$full_out" || fail "--stdout should include the full report body"

# --- config: defaults when key absent; values when present ---
cfg_absent="$work/absent.yml"; printf 'layer: 2\n' > "$cfg_absent"
out="$(bash "$ROOT/scripts/read-token-journey-config.sh" "$cfg_absent")"
grep -qx 'enabled=false' <<<"$out" || fail "absent token_journey should default enabled=false"
grep -qx 'output_dir=.arboretum/token-journey' <<<"$out" || fail "absent should default output_dir"
grep -qx 'format=md' <<<"$out" || fail "absent should default format=md"
cfg_set="$work/set.yml"
printf 'token_journey:\n  enabled: true\n  output_dir: .arboretum/tj\n  format: json\n' > "$cfg_set"
out="$(bash "$ROOT/scripts/read-token-journey-config.sh" "$cfg_set")"
grep -qx 'enabled=true' <<<"$out" || fail "should read enabled=true"
grep -qx 'output_dir=.arboretum/tj' <<<"$out" || fail "should read output_dir"
grep -qx 'format=json' <<<"$out" || fail "should read format=json"

# --- CLI: token-report.sh journey dispatches and writes an artifact ---
out="$(ARBORETUM_TRANSCRIPT="$main" bash "$ROOT/scripts/token-report.sh" journey --output-dir "$work/j-cli" --descriptor issue-627)"
grep -qiE 'token-journey report:' <<<"$out" || fail "journey arm did not run"
[ -n "$(ls "$work/j-cli" 2>/dev/null)" ] || fail "journey arm wrote no artifact"
# missing transcript -> exit 2 (matches busts)
if bash "$ROOT/scripts/token-report.sh" journey --output-dir "$work/j-x" 2>/dev/null; then
  fail "journey with no transcript should exit non-zero"
fi

# --- defense in depth: transcript-derived labels must be control-char scrubbed ---
# A Bash command carrying an ANSI escape must not leak the raw control byte into
# the rendered output (stdout or report). Mirrors the CLAUDE.md scrub invariant.
inj="$work/sess-inj.jsonl"
printf '%s\n' '{"uuid":"j1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"jm1","model":"claude-opus-4","content":[{"type":"tool_use","id":"jb","name":"Bash","input":{"command":"cat \u001b[31mevil"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}' > "$inj"
printf '%s\n' '{"uuid":"j2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"jm2","content":[{"type":"tool_result","tool_use_id":"jb","content":"X"}]}}' >> "$inj"
inj_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$inj" --stdout)"
if printf '%s' "$inj_out" | LC_ALL=C grep -q "$(printf '\033')"; then
  fail "control char (ESC) leaked into rendered output — scrub missing (CLAUDE.md defense-in-depth)"
fi
grep -qi 'Bash cat' <<<"$inj_out" || fail "scrub should strip control chars but keep the printable label"

# --- format json: the artifact must be REAL JSON, not a text table with a .json ext ---
pj="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j-json" --descriptor issue-627 --format json | sed -n 's/^token-journey report: //p')"
case "$pj" in *.json) :;; *) fail "json format should produce a .json artifact: $pj";; esac
python3 -m json.tool "$pj" >/dev/null 2>&1 || fail "--format json artifact is not valid JSON (hollow contract)"

# --- config errors must surface, not silently default ---
badcfgdir="$work/badcfg"; mkdir -p "$badcfgdir/out"
printf 'token_journey:\n  format: xml\n' > "$badcfgdir/.arboretum.yml"
cp "$main" "$badcfgdir/t.jsonl"
if ( cd "$badcfgdir" && ARBORETUM_TRANSCRIPT="t.jsonl" bash "$ROOT/scripts/token-report.sh" journey --output-dir out >/dev/null 2>&1 ); then
  fail "invalid .arboretum.yml should make journey arm exit non-zero (not silently default)"
fi

echo "PASS token-journey"
