#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
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

# RMS-6 — type:epic exemption (#891). A merged PR with a closing keyword
# referencing a live epic must NOT pull that epic into auto_close (or
# soft_resolved) — closing the parent would orphan its children. A non-epic
# with the same closing ref must still land in auto_close (regression guard).
epic_iss="$(mktemp)"; epic_prs="$(mktemp)"
cat > "$epic_iss" <<'EOF'
[
  {"number":516,"title":"Slipstream epic","body":"Parent epic tracking pipeline work.","labels":[{"name":"type:epic"},{"name":"horizon:now"}],"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-15T00:00:00Z"},
  {"number":700,"title":"Child fix","body":"A child fix.","labels":[{"name":"type:bug"},{"name":"horizon:now"}],"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-15T00:00:00Z"}
]
EOF
cat > "$epic_prs" <<'EOF'
[
  {"number":522,"title":"Child PR","body":"Closes #516. Closes #700.","mergedAt":"2026-05-14T00:00:00Z"}
]
EOF
epic_scan="$(bash "$SCAN" --issues-file "$epic_iss" --prs-file "$epic_prs" --as-of 2026-05-16)"; rc6=$?
b516="$(bucket_of "$epic_scan" 516)"
b700="$(bucket_of "$epic_scan" 700)"
rm -f "$epic_iss" "$epic_prs"
if [ "$rc6" = 0 ] && [ "$b516" != auto_close ] && [ "$b516" != soft_resolved ] && [ "$b700" = auto_close ]; then
  pass RMS-6
else
  fail_case RMS-6 "epic#516=$b516 (want NOT auto_close/soft_resolved) child#700=$b700 (want auto_close)"
fi

# RMS-7 — large payload must not overflow ARG_MAX (#890). The classifier
# fed the full --json issues/prs blobs to jq on argv; on a mature board the
# payload exceeded the OS argument-list limit and the scan died with
# "Argument list too long". Drive the file-input path with a >2 MB synthetic
# board and assert the scan completes (rc=0, no overflow message).
big_iss="$(mktemp)"; big_prs="$(mktemp)"
jq -n '[range(0;200) | {number:(.+1), title:"Issue \(.)", body:("x" * 12000), labels:[{name:"horizon:now"}], createdAt:"2026-05-10T00:00:00Z", updatedAt:"2026-05-15T00:00:00Z"}]' > "$big_iss"
echo '[]' > "$big_prs"
big_out="$(bash "$SCAN" --issues-file "$big_iss" --prs-file "$big_prs" --as-of 2026-05-16 2>&1)"; rc7=$?
rm -f "$big_iss" "$big_prs"
if [ "$rc7" = 0 ] && ! printf '%s' "$big_out" | grep -q "Argument list too long"; then
  pass RMS-7
else
  big_out_head="$(printf '%s' "$big_out" | head -1)"
  fail_case RMS-7 "rc=$rc7 out=$big_out_head"
fi

# RMS-8 — epic with recent PR mention must NOT be orphaned.
# An old epic whose updatedAt is >90 days ago still has active work signalled by
# a recently-merged PR. The epic-exemption spirit (introduced for #891) extends
# to the orphan bucket: if a type:epic has any recent PR reference (closing or
# mention), it stays out of orphan and lands in healthy.
rms8_iss="$(mktemp)"; rms8_prs="$(mktemp)"
cat > "$rms8_iss" <<'FIXTURE'
[
  {"number":600,"title":"Old epic with recent child","body":"An old epic.","labels":[{"name":"type:epic"},{"name":"horizon:now"}],"createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z"},
  {"number":601,"title":"Old non-epic same age","body":"Old non-epic.","labels":[{"name":"horizon:now"}],"createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z"}
]
FIXTURE
cat > "$rms8_prs" <<'FIXTURE'
[
  {"number":620,"title":"Child work","body":"Relates to #600.","mergedAt":"2026-05-15T00:00:00Z"}
]
FIXTURE
rms8_scan="$(bash "$SCAN" --issues-file "$rms8_iss" --prs-file "$rms8_prs" --as-of 2026-05-16)"; rc8=$?
b600="$(bucket_of "$rms8_scan" 600)"
b601="$(bucket_of "$rms8_scan" 601)"
rm -f "$rms8_iss" "$rms8_prs"
if [ "$rc8" = 0 ] && [ "$b600" != "orphan" ] && [ "$b601" = "orphan" ]; then
  pass RMS-8
else
  fail_case RMS-8 "epic#600=$b600 (want NOT orphan) non-epic#601=$b601 (want orphan)"
fi

[ "$fail" = 0 ] && echo "roadmap-maintain-scan contract: ALL PASS" || exit 1
