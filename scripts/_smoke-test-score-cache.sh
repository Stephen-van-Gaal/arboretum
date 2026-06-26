#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# ci-parallel: safe
# Smoke test for scripts/roadmap/score-cache.sh --validate-record
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$SCRIPT_DIR/roadmap/score-cache.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1 (got '$2' want '$3')"; fail=1; fi; }

valid='{"value":"low","value_description":"x","posture":"live","hazard":"none","complexity":"bugfix","blocker":"none","depends_on":[],"disposition":"keep","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26"}'
printf '%s' "$valid" | bash "$SC" --validate-record; check "valid record exits 0" "$?" "0"

bad='{"value":"WRONG","value_description":"x","posture":"live","hazard":"none","complexity":"bugfix","blocker":"none","depends_on":[],"disposition":"keep","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26"}'
printf '%s' "$bad" | bash "$SC" --validate-record 2>/dev/null; check "bad value enum exits 3" "$?" "3"

combine_missing_anchor='{"value":"high","value_description":"x","posture":"live","hazard":"none","complexity":"design","blocker":"spec","depends_on":[],"disposition":"combine","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26"}'
printf '%s' "$combine_missing_anchor" | bash "$SC" --validate-record 2>/dev/null; check "combine without anchor exits 3" "$?" "3"

# --diff: issue 1 unchanged (sha match), issue 2 changed (sha differ), issue 3 new, cached 9 no longer open
tmpc="$(mktemp)"
sha1="$(printf '%s' "body-one" | shasum -a 256 | cut -c1-12)"
cat > "$tmpc" <<EOF
{"1":{"body_sha":"$sha1"},"2":{"body_sha":"000000000000"},"9":{"body_sha":"abc123abc123"}}
EOF
issues='[{"number":1,"body":"body-one","labels":[]},{"number":2,"body":"body-two","labels":[]},{"number":3,"body":"body-three","labels":[]}]'
out="$(printf '%s' "$issues" | bash "$SC" --diff --cache "$tmpc")"
stale="$(printf '%s' "$out" | jq -c '.stale|sort')"
evict="$(printf '%s' "$out" | jq -c '.evict|sort')"
check "diff stale = [2,3]" "$stale" "[2,3]"
check "diff evict = [9]" "$evict" "[9]"
rm -f "$tmpc"

# --merge: scrub control chars in value_description, drop evicted, add new
tmpc="$(mktemp)"; echo '{"9":{"value":"low"}}' > "$tmpc"
ctrl="$(printf 'desc\x07with\x1bbell')"
upd="$(jq -n --arg d "$ctrl" '[{number:5,record:{value:"high",value_description:$d,posture:"live",hazard:"none",complexity:"bugfix",blocker:"none",depends_on:[],disposition:"keep",class:"work-unit",body_sha:"aaaaaaaaaaaa",scored:"2026-06-26"}}]')"
merged="$(printf '%s' "$upd" | bash "$SC" --merge --cache "$tmpc" --evict '[9]')"
desc="$(printf '%s' "$merged" | jq -r '."5".value_description')"
check "merge scrubs control chars" "$desc" "descwithbell"
check "merge drops evicted 9" "$(printf '%s' "$merged" | jq 'has("9")')" "false"
# agent-ready-list
cat > "$tmpc" <<'EOF'
{"5":{"value":"high","complexity":"bugfix","blocker":"none","disposition":"keep","class":"work-unit"},
 "6":{"value":"low","complexity":"design","blocker":"spec","disposition":"keep","class":"work-unit"}}
EOF
arl="$(bash "$SC" --agent-ready-list --cache "$tmpc" | tr '\n' ',')"
check "agent-ready-list = 5," "$arl" "5,"
rm -f "$tmpc"

# Finding 1: jq failure must propagate as non-zero (not masked by rm -f cleanup).
# --merge with invalid --evict JSON: jq parse error should exit non-zero.
printf '[]' | bash "$SC" --merge --cache /dev/null --evict 'NOT-VALID-JSON' 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - merge bad evict JSON exits non-zero" || { echo "FAIL - merge bad evict should fail non-zero"; fail=1; }
# --diff with corrupt cache content: jq --slurpfile parse error should exit non-zero.
tmpc_corrupt="$(mktemp)"
echo 'CORRUPT JSON DATA' > "$tmpc_corrupt"
printf '[{"number":1,"body":"test","labels":[]}]' | bash "$SC" --diff --cache "$tmpc_corrupt" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - diff corrupt cache exits non-zero" || { echo "FAIL - diff corrupt cache should fail non-zero"; fail=1; }
rm -f "$tmpc_corrupt"

# Finding 6: validator rejects floats for depends_on items, anchor, priority_driver.
float_depends='{"value":"low","value_description":"x","posture":"live","hazard":"none","complexity":"bugfix","blocker":"none","depends_on":[1.5],"disposition":"keep","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26"}'
printf '%s' "$float_depends" | bash "$SC" --validate-record 2>/dev/null; check "depends_on float rejected (exit 3)" "$?" "3"
float_anchor='{"value":"high","value_description":"x","posture":"live","hazard":"none","complexity":"design","blocker":"spec","depends_on":[],"disposition":"combine","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26","anchor":5.5,"priority_driver":3}'
printf '%s' "$float_anchor" | bash "$SC" --validate-record 2>/dev/null; check "combine anchor float rejected (exit 3)" "$?" "3"
float_pd='{"value":"high","value_description":"x","posture":"live","hazard":"none","complexity":"design","blocker":"spec","depends_on":[],"disposition":"combine","class":"work-unit","body_sha":"f5d3b38d61eb","scored":"2026-06-26","anchor":5,"priority_driver":2.7}'
printf '%s' "$float_pd" | bash "$SC" --validate-record 2>/dev/null; check "combine priority_driver float rejected (exit 3)" "$?" "3"

# body_sha parity: score-cache --diff must hash identically to agent-prep's convention.
b="some issue body"
expect="$(printf '%s' "$b" | shasum -a 256 | cut -c1-12)"
issues="$(jq -n --arg b "$b" '[{number:42,body:$b,labels:[]}]')"
out="$(printf '%s' "$issues" | bash "$SC" --diff --cache <(echo "{\"42\":{\"body_sha\":\"$expect\"}}"))"
check "body_sha parity (unchanged → not stale)" "$(printf '%s' "$out" | jq -c '.stale')" "[]"

# Finding 1 (Codex): emit_diff must reject empty or non-array stdin rather than silently
# evicting the whole cache.
tmpc_f1="$(mktemp)"
echo '{"10":{"body_sha":"aabbccdd1234"}}' > "$tmpc_f1"
printf '' | bash "$SC" --diff --cache "$tmpc_f1" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - diff empty stdin exits non-zero (Finding 1 Codex)" \
  || { echo "FAIL - diff empty stdin should exit non-zero"; fail=1; }
printf 'NOT-JSON' | bash "$SC" --diff --cache "$tmpc_f1" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - diff malformed JSON stdin exits non-zero (Finding 1 Codex)" \
  || { echo "FAIL - diff malformed JSON stdin should exit non-zero"; fail=1; }
printf '{}' | bash "$SC" --diff --cache "$tmpc_f1" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - diff non-array JSON stdin exits non-zero (Finding 1 Codex)" \
  || { echo "FAIL - diff non-array JSON stdin should exit non-zero"; fail=1; }
rm -f "$tmpc_f1"

# Finding 4 (Codex): emit_merge must reject empty or non-array stdin (exit non-zero so the
# caller's "> tmp && mv" pipeline does not replace the cache with bad data).
# (An empty JSON array [] is valid for merge — means no new scores, apply evictions only.)
tmpc_f4="$(mktemp)"
echo '{"11":{"value":"high"}}' > "$tmpc_f4"
printf '' | bash "$SC" --merge --cache "$tmpc_f4" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - merge empty string stdin exits non-zero (Finding 4 Codex)" \
  || { echo "FAIL - merge empty string stdin should exit non-zero"; fail=1; }
printf 'CORRUPT-JSON' | bash "$SC" --merge --cache "$tmpc_f4" 2>/dev/null
[ "$?" -ne 0 ] && echo "ok - merge corrupt JSON stdin exits non-zero (Finding 4 Codex)" \
  || { echo "FAIL - merge corrupt JSON stdin should exit non-zero"; fail=1; }
# Confirm valid [] still accepted (no-op merge returns the cache unchanged).
merged_empty="$(printf '[]' | bash "$SC" --merge --cache "$tmpc_f4")"
mc_rc=$?
if [ "$mc_rc" -eq 0 ] && printf '%s' "$merged_empty" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "ok - merge empty array [] exits zero with valid JSON (no-op)"
else
  echo "FAIL - merge [] should be valid (no-op merge)"; fail=1
fi
rm -f "$tmpc_f4"

exit $fail
