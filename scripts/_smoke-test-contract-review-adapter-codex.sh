#!/usr/bin/env bash
# owner: review-stage
# _smoke-test-contract-review-adapter-codex.sh — Contract test for
# docs/contracts/review-adapter-codex.cli-contract.md. Asserts RAC-1..RAC-7 against
# scripts/review-adapter-codex.sh using a fixture codex --json payload (no live codex
# call). Picked up by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/review-adapter-codex.sh"
VALIDATOR="$SCRIPT_DIR/validate-review-manifest.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

cat > "$FIX/codex.json" <<'JSON'
{ "verdict": "needs-attention",
  "summary": "One real bug, one nit.",
  "findings": [
    { "severity":"critical","title":"ValueError on oversized int","body":"digit limit","file":"scripts/lib/journey_render.py","line_start":75,"line_end":75,"confidence":0.9,"recommendation":"Widen the except to ValueError." },
    { "severity":"low","title":"naming","body":"rename x","file":"a.sh","line_start":3,"line_end":3,"confidence":0.4,"recommendation":"" }
  ],
  "next_steps": [] }
JSON

# RAC-1 — output validates against the shared review-manifest schema
out="$(bash "$PROBE" "$FIX/codex.json")"; rc=$?
printf '%s' "$out" > "$FIX/manifest.json"
if [ "$rc" = 0 ] && bash "$VALIDATOR" "$FIX/manifest.json" >/dev/null 2>&1; then pass RAC-1; else fail_case RAC-1 "rc=$rc out=$out"; fi

# RAC-2 — lane is "codex"; provenance preserved
[ "$(printf '%s' "$out" | jq -r '.lane')" = "codex" ] && pass RAC-2 || fail_case RAC-2 "$out"

# RAC-3 — severity map: critical→critical, low→info
sevs="$(printf '%s' "$out" | jq -r '[.findings[].severity] | join(",")')"
[ "$sevs" = "critical,info" ] && pass RAC-3 || fail_case RAC-3 "$sevs"

# RAC-4 — location is file:line_start; recommendation falls back to title — body when empty
loc="$(printf '%s' "$out" | jq -r '.findings[0].location')"
rec2="$(printf '%s' "$out" | jq -r '.findings[1].recommendation')"
[ "$loc" = "scripts/lib/journey_render.py:75" ] && [ "$rec2" = "naming — rename x" ] && pass RAC-4 || fail_case RAC-4 "loc=$loc rec2=$rec2"

# RAC-5 — files_reviewed is the unique set of finding files
fr="$(printf '%s' "$out" | jq -c '.files_reviewed')"
[ "$fr" = '["a.sh","scripts/lib/journey_render.py"]' ] && pass RAC-5 || fail_case RAC-5 "$fr"

# RAC-6 — scrub: a control char (ANSI escape) in codex text does not reach the manifest
dirty="$(printf '{"summary":"ok","findings":[{"severity":"high","title":"t","body":"x\x1b[31m","file":"f.sh","line_start":1,"line_end":1,"confidence":0.5,"recommendation":"r\x1b[0m"}]}')"
out2="$(printf '%s' "$dirty" | bash "$PROBE")"
case "$out2" in
  *$'\x1b'*) fail_case RAC-6 "ANSI escape survived into manifest" ;;
  *) [ "$(printf '%s' "$out2" | jq -r '.findings[0].severity')" = "warning" ] && pass RAC-6 || fail_case RAC-6 "high→warning failed: $out2" ;;
esac

# RAC-7 — non-codex input → exit 2
echo '{"no":"findings"}' | bash "$PROBE" >/dev/null 2>&1
[ "$?" = 2 ] && pass RAC-7 || fail_case RAC-7 "expected exit 2 on non-codex input"

[ "$fail" = 0 ] && echo "review-adapter-codex contract: ALL PASS" || exit 1
