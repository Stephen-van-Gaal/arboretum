#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# _smoke-test-merge-review-manifests.sh — unit test for scripts/merge-review-manifests.sh
# (#791 D6). Asserts MRM-1..MRM-7: the deterministic, LLM-free merge of N review
# manifests → one ReviewResult (dedup by (location, normalized recommendation), max
# severity on collision, lane provenance, reviewers_run / reviewers_degraded).
# Picked up by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/merge-review-manifests.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# Two well-formed manifests (each validates against the manifest schema).
cat > "$FIX/ai.json" <<'JSON'
{ "lane":"ai-surface", "files_reviewed":["skills/x/SKILL.md"], "surface_identified":"diff",
  "coverage":[{"category":"injection","status":"evaluated","why":"checked prompts"}],
  "findings":[{"severity":"warning","location":"skills/x/SKILL.md:10","recommendation":"Quote untrusted input."}] }
JSON
cat > "$FIX/codex.json" <<'JSON'
{ "lane":"codex", "files_reviewed":["a.sh","skills/x/SKILL.md"], "surface_identified":"diff",
  "coverage":[{"category":"codex-review","status":"evaluated","why":"branch scan"}],
  "findings":[
    {"severity":"info","location":"a.sh:3","recommendation":"Rename x."},
    {"severity":"critical","location":"skills/x/SKILL.md:10","recommendation":"quote   untrusted INPUT."}
  ] }
JSON

# MRM-1 — two manifests merge; reviewers_run preserves dispatch (input) order; files_reviewed unioned/sorted.
out="$(bash "$PROBE" "$FIX/ai.json" "$FIX/codex.json")"; rc=$?
if [ "$rc" = 0 ]; then
  rr="$(printf '%s' "$out" | jq -c '.reviewers_run')"
  fr="$(printf '%s' "$out" | jq -c '.files_reviewed')"
  [ "$rr" = '["ai-surface","codex"]' ] && [ "$fr" = '["a.sh","skills/x/SKILL.md"]' ] \
    && pass MRM-1 || fail_case MRM-1 "rr=$rr fr=$fr"
else fail_case MRM-1 "rc=$rc out=$out"; fi

# MRM-2 — same location + same (normalized) recommendation dedupes to ONE finding with both lanes.
nf="$(printf '%s' "$out" | jq '[.findings[] | select(.location=="skills/x/SKILL.md:10")] | length')"
lanes="$(printf '%s' "$out" | jq -c 'first(.findings[] | select(.location=="skills/x/SKILL.md:10")) | .lanes')"
[ "$nf" = 1 ] && [ "$lanes" = '["ai-surface","codex"]' ] && pass MRM-2 || fail_case MRM-2 "nf=$nf lanes=$lanes"

# MRM-3 — severity collision resolves to the max (warning + critical → critical).
sev="$(printf '%s' "$out" | jq -r 'first(.findings[] | select(.location=="skills/x/SKILL.md:10")) | .severity')"
[ "$sev" = critical ] && pass MRM-3 || fail_case MRM-3 "sev=$sev"

# MRM-4 — --degraded populates reviewers_degraded and is absent from reviewers_run.
out4="$(bash "$PROBE" --degraded general-security,docs "$FIX/ai.json")"
deg="$(printf '%s' "$out4" | jq -c '.reviewers_degraded')"
inrun="$(printf '%s' "$out4" | jq '[.reviewers_run[] | select(.=="general-security")] | length')"
[ "$deg" = '["general-security","docs"]' ] && [ "$inrun" = 0 ] && pass MRM-4 || fail_case MRM-4 "deg=$deg inrun=$inrun"

# MRM-5 — recommendation normalization: case + internal whitespace differences collapse (already
# exercised by MRM-2's "Quote untrusted input." vs "quote   untrusted INPUT."). Assert the kept
# recommendation is the max-severity finding's verbatim text (critical wins).
rec="$(printf '%s' "$out" | jq -r 'first(.findings[] | select(.location=="skills/x/SKILL.md:10")) | .recommendation')"
[ "$rec" = "quote   untrusted INPUT." ] && pass MRM-5 || fail_case MRM-5 "rec=$rec"

# MRM-6 — degenerate (1 manifest): ReviewResult wraps it, findings preserved 1:1.
out6="$(bash "$PROBE" "$FIX/ai.json")"
n6="$(printf '%s' "$out6" | jq '.findings | length')"
rr6="$(printf '%s' "$out6" | jq -c '.reviewers_run')"
[ "$n6" = 1 ] && [ "$rr6" = '["ai-surface"]' ] && pass MRM-6 || fail_case MRM-6 "n6=$n6 rr6=$rr6"

# MRM-7 — coverage entries carry lane provenance.
cov="$(printf '%s' "$out" | jq -c '[.coverage[].lane] | sort')"
[ "$cov" = '["ai-surface","codex"]' ] && pass MRM-7 || fail_case MRM-7 "cov=$cov"

# MRM-8 — --degraded tolerates a trailing comma without leaking an empty "" id.
out8="$(bash "$PROBE" --degraded "general-security," "$FIX/ai.json")"
deg8="$(printf '%s' "$out8" | jq -c '.reviewers_degraded')"
[ "$deg8" = '["general-security"]' ] && pass MRM-8 || fail_case MRM-8 "deg8=$deg8"

[ "$fail" = 0 ] && echo "merge-review-manifests: ALL PASS" || exit 1
