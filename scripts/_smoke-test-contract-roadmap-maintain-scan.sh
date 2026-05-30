#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-maintain-scan.sh — Contract test for
# docs/contracts/roadmap-maintain-scan.contract.md. Asserts RMS-1..RMS-5
# against scripts/roadmap/maintain-scan.sh.
#
# The scanner supports a file-driven test mode (--issues-file / --prs-file
# / --as-of) that needs no gh, so we drive it against the committed
# fixtures under scripts/_fixtures/roadmap/ with a pinned as-of date. This
# asserts the *scan-JSON protocol* (top-level keys, bucket name set +
# precedence, per-entry {number,title,evidence}) that maintain-apply.sh
# consumes — distinct from the existing _smoke-test-roadmap-maintain.sh,
# which exercises the full classify→apply flow. Picked up automatically by
# ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/roadmap/maintain-scan.sh"
ISSUES="$SCRIPT_DIR/_fixtures/roadmap/maintain-issues.json"
PRS="$SCRIPT_DIR/_fixtures/roadmap/maintain-prs.json"
[ -f "$SCAN" ]   || { echo "FAIL: $SCAN not found" >&2; exit 1; }
[ -f "$ISSUES" ] || { echo "FAIL: $ISSUES not found" >&2; exit 1; }
[ -f "$PRS" ]    || { echo "FAIL: $PRS not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

bucket_of() {  # which bucket holds issue $1, or MISSING
  printf '%s' "$1" | jq -r --argjson n "$2" \
    '.buckets | to_entries | map(select(.value | any(.number == $n))) | (.[0].key // "MISSING")'
}

scan="$(bash "$SCAN" --issues-file "$ISSUES" --prs-file "$PRS" --as-of 2026-05-16)"; rc=$?

# RMS-1 — valid JSON, EXACTLY the two top-level keys buckets + counts (objects).
# (keys|sort)==["buckets","counts"] asserts the exact key set per the contract's
# "exactly two top-level keys" invariant — a regression adding a third top-level
# key fails here rather than slipping through a presence-only check.
if [ "$rc" = 0 ] \
   && printf '%s' "$scan" | jq -e '(keys|sort) == ["buckets","counts"]' >/dev/null 2>&1 \
   && printf '%s' "$scan" | jq -e '(.buckets|type=="object") and (.counts|type=="object")' >/dev/null 2>&1; then
  pass RMS-1
else
  fail_case RMS-1 "rc=$rc scan=$scan"
fi

# RMS-2 — bucket name set + precedence (per committed fixtures)
b1=$(bucket_of "$scan" 1)   # closing-keyword PR → auto_close
b3=$(bucket_of "$scan" 3)   # mention without closing keyword → soft_resolved
b4=$(bucket_of "$scan" 4)   # old + no horizon → orphan
b5=$(bucket_of "$scan" 5)   # no horizon:* → untriaged
if [ "$b1" = auto_close ] && [ "$b3" = soft_resolved ] && [ "$b4" = orphan ] && [ "$b5" = untriaged ]; then
  pass RMS-2
else
  fail_case RMS-2 "b1=$b1 b3=$b3 b4=$b4 b5=$b5"
fi

# RMS-3 — every bucketed entry carries number, title, non-empty evidence
bad="$(printf '%s' "$scan" | jq '[.buckets[][] | select((has("number")|not) or (has("title")|not) or (.evidence == "") or (.evidence == null))] | length')"
[ "$bad" = 0 ] && pass RMS-3 || fail_case RMS-3 "$bad entries malformed"

# RMS-4 — healthy omitted from buckets but counted; counts sum = fixture count
healthy_in_buckets="$(printf '%s' "$scan" | jq 'if (.buckets | has("healthy")) then 1 else 0 end')"
total_issues="$(jq 'length' "$ISSUES")"
counts_sum="$(printf '%s' "$scan" | jq '[.counts | to_entries[].value] | add')"
healthy_count="$(printf '%s' "$scan" | jq '.counts.healthy')"
if [ "$healthy_in_buckets" = 0 ] && [ "$counts_sum" = "$total_issues" ] && [ -n "$healthy_count" ] && [ "$healthy_count" -ge 1 ]; then
  pass RMS-4
else
  fail_case RMS-4 "healthy_in_buckets=$healthy_in_buckets counts_sum=$counts_sum total=$total_issues healthy=$healthy_count"
fi

# RMS-5 — unknown flag → exit 2
bash "$SCAN" --bogus >/dev/null 2>&1; rc5=$?
[ "$rc5" = 2 ] && pass RMS-5 || fail_case RMS-5 "rc=$rc5"

[ "$fail" = 0 ] && echo "roadmap-maintain-scan contract: ALL PASS" || exit 1
