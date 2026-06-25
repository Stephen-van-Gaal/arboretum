#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# _smoke-test-review-stage-integration.sh — #791 integration test (section-dispatch
# ceiling): one fan-out mixing a RUNTIME reviewer (codex, via the real D5 adapter) and a
# SKILL reviewer (a fixture manifest standing in for a fresh-context driver's return) is
# reconciled by the real D6 merge into ONE ReviewResult that honours the shared schema.
# The deterministic spine (registry-select → runtime adapter → merge) runs for real; only
# the skill-driver subagent — inherently an agent-runtime concern — is fixtured.
# Picked up by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REG="$REPO_ROOT/reviewers.yml"
ADAPTER="$SCRIPT_DIR/review-adapter-codex.sh"
MERGE="$SCRIPT_DIR/merge-review-manifests.sh"
FILTER="$SCRIPT_DIR/review-registry-filter.sh"
VALIDATOR="$SCRIPT_DIR/validate-review-manifest.sh"
for f in "$ADAPTER" "$MERGE" "$FILTER" "$VALIDATOR"; do [ -f "$f" ] || { echo "FAIL: $f not found" >&2; exit 1; }; done

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# INT-1 — the registry expresses a HETEROGENEOUS fan-out: at finish/diff over an
# AI-facing + code change, the selection includes both a skill row and the runtime row.
files=$'skills/x/SKILL.md\nlib/foo.ts'
sel="$(printf '%s\n' "$files" | bash "$FILTER" "$REG" --altitude finish --artifact diff --files-from -)"
types="$(printf '%s' "$sel" | jq -rs '[.[].type] | unique | join(",")')"
[ "$types" = "runtime,skill" ] && pass INT-1 || fail_case INT-1 "selected types: $types"

# Build the runtime manifest for real from a codex --json fixture (D5 adapter).
cat > "$FIX/codex.json" <<'JSON'
{ "verdict":"needs-attention", "summary":"shared + unique",
  "findings":[
    { "severity":"critical","title":"injection","body":"unquoted","file":"skills/x/SKILL.md","line_start":10,"line_end":10,"confidence":0.9,"recommendation":"Quote untrusted input." },
    { "severity":"low","title":"nit","body":"x","file":"lib/foo.ts","line_start":3,"line_end":3,"confidence":0.3,"recommendation":"Rename foo." }
  ] }
JSON
bash "$ADAPTER" "$FIX/codex.json" > "$FIX/m_codex.json"

# A skill driver's returned manifest (fixture) — overlaps codex on one finding.
cat > "$FIX/m_skill.json" <<'JSON'
{ "lane":"ai-surface", "files_reviewed":["skills/x/SKILL.md"], "surface_identified":"diff",
  "coverage":[{"category":"injection","status":"evaluated","why":"prompt review"}],
  "findings":[{"severity":"warning","location":"skills/x/SKILL.md:10","recommendation":"quote untrusted input."}] }
JSON

# INT-2 — both worker manifests validate against the SAME schema (the replaceability seam).
if bash "$VALIDATOR" "$FIX/m_codex.json" >/dev/null 2>&1 && bash "$VALIDATOR" "$FIX/m_skill.json" >/dev/null 2>&1; then
  pass INT-2; else fail_case INT-2 "a worker manifest failed the shared schema"; fi

# Merge the mixed fan-out (D6).
result="$(bash "$MERGE" "$FIX/m_skill.json" "$FIX/m_codex.json")"

# INT-3 — one ReviewResult naming both contributing lanes.
rr="$(printf '%s' "$result" | jq -c '.reviewers_run')"
[ "$rr" = '["ai-surface","codex"]' ] && pass INT-3 || fail_case INT-3 "$rr"

# INT-4 — the shared finding (skills/x/SKILL.md:10, "quote untrusted input") deduped across
# the runtime + skill reviewer into ONE entry carrying both lanes, at the max severity.
shared="$(printf '%s' "$result" | jq -c 'first(.findings[] | select(.location=="skills/x/SKILL.md:10")) | {n: ([.lanes]|length), lanes:.lanes, sev:.severity}')"
nshared="$(printf '%s' "$result" | jq '[.findings[] | select(.location=="skills/x/SKILL.md:10")] | length')"
[ "$nshared" = 1 ] && [ "$(printf '%s' "$result" | jq -c 'first(.findings[]|select(.location=="skills/x/SKILL.md:10")).lanes')" = '["ai-surface","codex"]' ] \
  && [ "$(printf '%s' "$result" | jq -r 'first(.findings[]|select(.location=="skills/x/SKILL.md:10")).severity')" = critical ] \
  && pass INT-4 || fail_case INT-4 "$shared (n=$nshared)"

# INT-5 — the codex-only finding survives as its own entry (no over-collapsing).
n5="$(printf '%s' "$result" | jq '[.findings[] | select(.location=="lib/foo.ts:3")] | length')"
[ "$n5" = 1 ] && pass INT-5 || fail_case INT-5 "codex-only finding count=$n5"

[ "$fail" = 0 ] && echo "review-stage integration: ALL PASS" || exit 1
