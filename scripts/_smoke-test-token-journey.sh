#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# ci-parallel: safe
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-journey: $1" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# #708: isolate the state-dir so every bare (no --output-dir) read-session-journey
# / token-report journey call defaults under $work, never the real central store.
# arboretum_state_dir() honors ARBORETUM_STATE_DIR first (scripts/lib/state-dir.sh),
# so this one export covers all current and future bare call sites in this test.
# Value is the `.arboretum` dir itself (consumers append /token-journey), mirroring
# the real <main-checkout>/.arboretum convention so the device-stable path shape holds.
export ARBORETUM_STATE_DIR="$work/.arboretum"
main="$work/sess-abc.jsonl"

# Synthetic main transcript: one /design Skill turn, then a brainstorming Skill
# turn, then a priced model turn under each. cache_read=context, input/cache_creation/output=operation.
cat > "$main" <<'JSONL'
{"uuid":"u1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"m1","model":"claude-opus-4","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"arboretum:design"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"uuid":"u2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"m2","model":"claude-opus-4","content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"superpowers:brainstorming"}}],"usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000,"output_tokens":100}}}
JSONL

out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --stdout)"
grep -qiE '^\*\*design\*\*' <<<"$out" || fail "design stage header not rendered"
grep -qiE '^\| *Skill *\|' <<<"$out" || fail "skill table header not rendered"
grep -qiE 'brainstorming' <<<"$out" || fail "brainstorming skill not attributed under design"
# Cost math (opus rates: input 5, output 25, cache_write 6.25, cache_read 0.50 per 1M):
#   m1 (design):       ctx=0                op=(100*5 + 50*25)/1e6  = 0.00175
#   m2 (brainstorming): ctx=10000*0.50/1e6=0.005  op=(200*5 + 100*25)/1e6 = 0.00350
#   total = 0.005 + 0.00525 = 0.01025 -> renders 0.010 at 3dp
grep -qiE '\| *0\.010 *\|' <<<"$out" || fail "total cost math wrong (expected 0.010 in summary row)"
# #655 item 4: no subagents have been spawned yet (no sess-abc/subagents dir) →
# the artifact must say so explicitly, not silently omit the section.
grep -qiE 'subagents: none detected' <<<"$out" || fail "item4: 'subagents: none detected' missing when no subagents ran"

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
# #655 item 4: with subagents present, the "none detected" line must disappear.
grep -qiE 'none detected' <<<"$out" && fail "item4: 'none detected' must not appear when subagents are present"
grep -qiE 'Agent:Explore'         <<<"$out" || fail "grandchild subagent not joined (fixpoint failed)"
# both subagents must land under the design stage block, not (pre-workflow)
grep -qiE '^\*\*design\*\*' <<<"$out" || fail "subagents not attributed to design stage header"

# broken chain → warn, not crash
mkdir -p "$work/sess-broken/subagents"
echo '{"a":1}' > "$work/sess-broken.jsonl"
cat > "$work/sess-broken/subagents/agent-orphan.jsonl" <<'JSONL'
{"uuid":"o1","parentUuid":"does-not-exist","message":{"id":"om1","model":"claude-opus-4","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
JSONL
warn="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$work/sess-broken.jsonl" --stdout 2>&1 >/dev/null)"
grep -qiE 'warn.*unresolved' <<<"$warn" || fail "broken parentUuid should warn on stderr"
# #655 item 5: the same warning must be carried into the report BODY (footer),
# since under output-inversion (D8) the operator reads the file, not stderr.
broken_body="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$work/sess-broken.jsonl" --stdout 2>/dev/null)"
grep -qiE 'NOTES:' <<<"$broken_body" || fail "item5: warnings footer (NOTES:) missing from report body"
grep -qiE 'unresolved' <<<"$broken_body" || fail "item5: unresolved warning not carried into the in-file footer"
grep -qiE 'pre-workflow.*could not be resolved' <<<"$broken_body" || fail "item5: (pre-workflow) bucket left unexplained in footer"
# The broken fixture has an agent file present (just unresolved) → NOT "none detected".
grep -qiE 'none detected' <<<"$broken_body" && fail "item4: join-miss (agent present) must not report 'none detected'"

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

# --- #650 item 3: Bash intake label strips the `cd ... &&` navigation preamble ---
# Governance commands are prefixed `cd "$ROOT" && <cmd>`; the operative command,
# not the shared cd preamble, must be the grouping key.
cdp="$work/sess-cdprefix.jsonl"
cat > "$cdp" <<'JSONL'
{"uuid":"p1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"pm1","model":"claude-opus-4","content":[{"type":"tool_use","id":"pb","name":"Bash","input":{"command":"cd \"$ROOT\" && bash scripts/ci-checks.sh"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"uuid":"p2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"pm2","content":[{"type":"tool_result","tool_use_id":"pb","content":"YYYY"}]}}
JSONL
out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$cdp" --stdout)"
grep -qiE 'Bash bash scripts/ci-checks.sh' <<<"$out" || fail "item3: cd preamble not stripped from Bash intake label"
grep -qiE 'Bash cd ' <<<"$out" && fail "item3: cd preamble still dominates Bash intake label"

# --- #650 items 1+2 (md): ctx$/turn skill column + a priced intake ctx$ column ---
out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --stdout)"
grep -qiE 'ctx\$/t' <<<"$out" || fail "item2: ctx\$/turn column missing from skill row"
# intake header advertises an approximate dollar column priced at a model family (ctx$~<fam>)
grep -qiE 'ctx\$~' <<<"$out" || fail "item1: intake ctx\$ (approx) column missing from CONTEXT INTAKE header"

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
grep -qiE '^\| *Skill *\|' <<<"$default_out" && fail "default run leaked report body into stdout (D8 violation)"
grep -qiE 'token-journey report:' <<<"$default_out" || fail "default run should print a pointer line"
grep -qiE 'total\$' <<<"$default_out" || fail "pointer should include headline total\$"
# --stdout still dumps the full body
full_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j3" --descriptor "issue-627" --stdout)"
grep -qiE '^\*\*design\*\*' <<<"$full_out" || fail "--stdout should include the full report body"

# --- config: defaults when key absent; values when present ---
cfg_absent="$work/absent.yml"; printf 'layer: 2\n' > "$cfg_absent"
out="$(bash "$ROOT/scripts/read-token-journey-config.sh" "$cfg_absent")"
grep -qx 'enabled=false' <<<"$out" || fail "absent token_journey should default enabled=false"
# #673/D27: the default output_dir is device-stable — anchored at the main
# checkout (absolute), not the bare worktree-relative `.arboretum/token-journey`.
grep -qE '^output_dir=/.*/\.arboretum/token-journey$' <<<"$out" || fail "absent should default to main-checkout-anchored output_dir (got: $(grep '^output_dir=' <<<"$out"))"
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

# --- #651 D5: a literal | in a transcript-derived label must be escaped (\|)
# so it cannot break out of its GFM table cell or forge extra columns. ---
pipe="$work/sess-pipe.jsonl"
printf '%s\n' '{"uuid":"k1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"km1","model":"claude-opus-4","content":[{"type":"tool_use","id":"kb","name":"Bash","input":{"command":"grep -E a|b"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}' > "$pipe"
printf '%s\n' '{"uuid":"k2","timestamp":"2026-06-07T10:01:00Z","message":{"id":"km2","content":[{"type":"tool_result","tool_use_id":"kb","content":"Z"}]}}' >> "$pipe"
pipe_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$pipe" --stdout)"
grep -qE 'grep -E a\\\|b' <<<"$pipe_out" || fail "D5: literal | in a label must be escaped to \\| in the md cell"

# --- #651 D5 (B4 ai-surface hardening): a cell value must stay a single, inert
# table cell. Skill names / attribution labels are author-controlled and NOT
# line-clamped, so _mdcell must (a) collapse newlines/tabs so a \n cannot break
# the row and inject top-level markdown, and (b) escape <,> so raw HTML/<img>
# cannot render live. ---
inj2="$work/sess-mdinj.jsonl"
printf '%s\n' '{"uuid":"y1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"ym1","model":"claude-opus-4","content":[{"type":"tool_use","id":"yt","name":"Skill","input":{"skill":"evil\n# INJECTED HEADING\n<img src=x>&lt;b&gt;"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":5}}}' > "$inj2"
mdinj_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$inj2" --stdout)"
grep -qE '^#+ INJECTED' <<<"$mdinj_out" && fail "D5: a newline in a label broke the row and injected a markdown heading"
grep -qE '<img' <<<"$mdinj_out" && fail "D5: raw HTML in a label rendered live (<,> not escaped)"
grep -qi 'evil # INJECTED HEADING' <<<"$mdinj_out" || fail "D5: label should collapse to a single inert cell (newlines→space, html-escaped)"
# A literal & must be escaped to &amp; FIRST (canonical html.escape order) so an
# entity-encoded payload (e.g. &lt;b&gt;) can't survive as a decodable entity.
grep -q '&amp;' <<<"$mdinj_out" || fail "D5: literal & must be escaped to &amp; so entity-encoded HTML cannot reconstitute"

# --- format json: the artifact must be REAL JSON, not a text table with a .json ext ---
pj="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j-json" --descriptor issue-627 --format json | sed -n 's/^token-journey report: //p')"
case "$pj" in *.json) :;; *) fail "json format should produce a .json artifact: $pj";; esac
python3 -m json.tool "$pj" >/dev/null 2>&1 || fail "--format json artifact is not valid JSON (hollow contract)"

# --- #650 items 1+2 (json): skills carry context_per_turn; intake rows carry context_usd ---
pjb="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$big" --output-dir "$work/j-json-b" --descriptor big --format json | sed -n 's/^token-journey report: //p')"
python3 - "$pj" "$pjb" <<'PYCHK' || fail "json must carry context_per_turn (skills) and context_usd (intake)"
import json, sys
main = json.load(open(sys.argv[1]))
sk = main["stages"][0]["skills"][0]
assert "context_per_turn" in sk, "skill object missing context_per_turn"
assert sk["context_per_turn"] == round(sk["context"] / (sk["turns"] or 1), 6), "context_per_turn math wrong"
big = json.load(open(sys.argv[2]))
assert big["intake"], "big fixture should produce a non-empty intake table"
row = big["intake"][0]
assert "context_usd" in row, "intake row missing context_usd"
assert row["context_usd"] > 0, "context_usd should be a positive context-rent"
PYCHK

# --- config errors must surface, not silently default ---
badcfgdir="$work/badcfg"; mkdir -p "$badcfgdir/out"
printf 'token_journey:\n  format: xml\n' > "$badcfgdir/.arboretum.yml"
cp "$main" "$badcfgdir/t.jsonl"
if ( cd "$badcfgdir" && ARBORETUM_TRANSCRIPT="t.jsonl" bash "$ROOT/scripts/token-report.sh" journey --output-dir out >/dev/null 2>&1 ); then
  fail "invalid .arboretum.yml should make journey arm exit non-zero (not silently default)"
fi

# --- #655 item 6: no silent [:12] intake cap — a >12-source session must emit a
# "… +N more, $X remainder" line (md) and an intake_remainder object (json). ---
many="$work/sess-many.jsonl"
: > "$many"
for i in $(seq 1 14); do
  printf '{"uuid":"mu%s","timestamp":"2026-06-07T10:%02d:00Z","message":{"id":"mm%s","model":"claude-opus-4","content":[{"type":"tool_use","id":"mt%s","name":"Bash","input":{"command":"echo src%s"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$i" "$i" "$i" "$i" "$i" >> "$many"
  printf '{"uuid":"mr%s","timestamp":"2026-06-07T10:%02d:30Z","message":{"id":"mmr%s","content":[{"type":"tool_result","tool_use_id":"mt%s","content":"DATADATADATADATA"}]}}\n' "$i" "$i" "$i" "$i" >> "$many"
done
many_out="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$many" --stdout)"
grep -qE '… \+2 more, \$[0-9.]+ remainder' <<<"$many_out" || fail "item6: intake remainder line missing for >12 sources"

# --- #655 items 4+6 (json parity): subagents summary + intake_remainder + notes ---
pjm="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$many" --output-dir "$work/j-many" --descriptor many --format json | sed -n 's/^token-journey report: //p')"
pjs="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --output-dir "$work/j-main" --descriptor main --format json | sed -n 's/^token-journey report: //p')"
pjbroken="$(bash "$ROOT/scripts/read-session-journey.sh" --transcript "$work/sess-broken.jsonl" --output-dir "$work/j-broken" --descriptor broken --format json 2>/dev/null | sed -n 's/^token-journey report: //p')"
python3 - "$pjm" "$pjs" "$pjbroken" "$pjb" <<'PYCHK' || fail "json parity for #655 items 4/5/6 failed"
import json, sys
many, mainj, broken, big = (json.load(open(p)) for p in sys.argv[1:5])
# item 6: dropped intake tail surfaced, not silently capped
assert len(many["intake"]) == 12, "intake list should still be capped at 12 rows"
rem = many.get("intake_remainder")
assert rem and rem["more"] == 2, "intake_remainder.more should account for the 2 dropped sources"
assert rem["context_usd"] > 0, "intake_remainder.context_usd should be a positive remainder"
assert "intake_remainder" not in big, "no remainder object when <=12 sources"
# item 4: explicit subagent count (main has child+grandchild; big has none)
assert mainj["subagents"]["detected"] == 2, "main should report 2 detected subagents"
assert big["subagents"]["detected"] == 0, "big (no agent files) should report detected==0"
# item 5: warnings carried into json notes for an unresolved chain
assert broken.get("notes"), "broken-chain session should carry warnings in json notes"
assert any("unresolved" in n for n in broken["notes"]), "notes should name the unresolved chain"
PYCHK

# --- #708 regression guard: bare calls (no --output-dir) must resolve their
# default store under the ISOLATED state-dir, never the real central store.
# Positive assertion (robust to pre-existing pollution in the shared real store,
# where deterministic filenames would make an ls-diff false-pass on overwrite):
# a bare run must land its artifact under $work, proving ARBORETUM_STATE_DIR
# isolation is in effect. Without it, arboretum_state_dir falls back to the main
# checkout and the fixture leaks into the real .arboretum/token-journey store.
iso_store="$work/.arboretum/token-journey"
bash "$ROOT/scripts/read-session-journey.sh" --transcript "$main" --stdout >/dev/null
ls "$iso_store"/*.md >/dev/null 2>&1 \
  || fail "#708: a bare (no --output-dir) journey call did not write under the isolated state-dir ($iso_store) — it leaked to the real central store; export ARBORETUM_STATE_DIR=\"\$work/.arboretum\" at the top of this test"

echo "PASS token-journey"
