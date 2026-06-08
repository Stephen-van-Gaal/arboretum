#!/usr/bin/env bash
# owner: extract-shared-component
# Unit/smoke tests for the extract-component Tier-1/Tier-2 detectors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GREP_IDIOMS="skills/extract-component/scripts/grep-idioms.sh"
SHINGLE="skills/extract-component/scripts/shingle-detect.py"
CORPUS="tests/fixtures/extract-component/corpus"

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; fail=1; }

# Output is captured to temp files so JSON (with quotes/brackets/newlines) is read
# back by jq directly from disk, never re-embedded into a shell string.
t1_out="$(mktemp)"; t2_out="$(mktemp)"
trap 'rm -f "$t1_out" "$t2_out"' EXIT

# Tier 1: grep-idioms.sh accepts a corpus root and reports the scrub idiom across 3 files.
bash "$GREP_IDIOMS" "$CORPUS" >"$t1_out" 2>/dev/null || true
if grep -qi "scrub control-char" "$t1_out"; then pass "tier1: scrub idiom present"; else fail_case "tier1: scrub idiom present"; fi
# The files column for the scrub idiom must read 3 (planted in a,b,c).
if grep -i "scrub control-char" "$t1_out" | grep -qE "[[:space:]]3[[:space:]]"; then
  pass "tier1: scrub spans 3 files"; else fail_case "tier1: scrub spans 3 files"; fi

# Tier 2: shingle-detect.py finds the write_cache block across 3 files, clustered to ONE region.
printf '%s\n' "$CORPUS"/*.sh | python3 "$SHINGLE" 4 3 >"$t2_out" 2>/dev/null || true
if jq -e 'type == "array"' "$t2_out" >/dev/null 2>&1; then pass "tier2: emits JSON array"; else fail_case "tier2: emits JSON array"; fi
if jq -e '[.[] | select(.files >= 3)] | length >= 1' "$t2_out" >/dev/null 2>&1; then
  pass "tier2: write_cache candidate spans 3 files"; else fail_case "tier2: write_cache candidate spans 3 files"; fi
# Clustering: the repeated 4-line block must appear as ONE candidate region, not as
# multiple overlapping windows of the same block from the same file set.
if jq -e '[.[] | select(.files == 3)] | length == 1' "$t2_out" >/dev/null 2>&1; then
  pass "tier2: overlapping windows clustered to one region"; else fail_case "tier2: overlapping windows clustered to one region"; fi

if [ "$fail" -ne 0 ]; then echo "DETECTOR SMOKE TEST FAILED" >&2; exit 1; fi
echo "all detector smoke checks passed"
