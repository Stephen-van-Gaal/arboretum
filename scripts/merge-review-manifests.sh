#!/usr/bin/env bash
# owner: review-stage
# merge-review-manifests.sh — deterministic, LLM-free merge of N review manifests
# into one ReviewResult (#791 D6, section-dispatch element 6).
#
#   merge-review-manifests.sh [--degraded id,id,...] <manifest-file>...
#
# Each input is a worker manifest (docs/contracts/review-manifest.contract.md). Output
# is the merged ReviewResult: the union of files reviewed, lane-tagged coverage, and
# findings DEDUPED by (location, normalized recommendation) — the "rule" of the issue's
# (file,line,rule) key, since the manifest carries no separate rule field. On a dedup
# collision the highest severity wins (critical > warning > info) and lane provenance is
# unioned. reviewers_run names every contributing lane (in dispatch/input order);
# reviewers_degraded names backends that were absent (passed by the dispatcher).
#
# Merge is reconciliation only — it adds NO judgement. Semantic dedupe (two differently
# worded findings about the same defect) is deliberately out of scope: that would need an
# LLM, and this is the LLM-free floor. A degenerate fan-out (one worker) skips merge at
# the dispatcher; invoked on one manifest here it still returns a well-formed ReviewResult.
set -euo pipefail

DEGRADED='[]'
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --degraded)
      shift
      DEGRADED="$(printf '%s' "${1:-}" | jq -R 'split(",") | map(select(. != ""))')"
      shift ;;
    -*) echo "merge-review-manifests: unknown flag $1" >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

[ "${#files[@]}" -ge 1 ] || { echo "usage: merge-review-manifests.sh [--degraded id,...] <manifest>..." >&2; exit 2; }
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "merge-review-manifests: file not found: $f" >&2; exit 2; }
done

jq -s --argjson degraded "$DEGRADED" '
  def sevrank: {"critical":3,"warning":2,"info":1}[.] // 0;
  # normalize a recommendation into a dedup key part: lowercase, trim, collapse whitespace.
  def normrec: (. // "") | ascii_downcase | gsub("^\\s+|\\s+$";"") | gsub("\\s+";" ");
  # order-preserving unique (jq unique sorts; dispatch order is meaningful for lanes).
  def ouniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  {
    reviewers_run: ([.[].lane] | ouniq),
    reviewers_degraded: $degraded,
    files_reviewed: ([.[].files_reviewed[]] | unique),
    coverage: [ .[] as $m | $m.coverage[] | . + {lane: $m.lane} ],
    findings: (
      [ .[] as $m | $m.findings[] | . + {lane: $m.lane} ]
      | group_by(.location + "\u001f" + (.recommendation | normrec))
      | map(
          (max_by(.severity | sevrank)) as $top
          | { severity: $top.severity,
              location: $top.location,
              recommendation: $top.recommendation,
              lanes: ([.[].lane] | ouniq) }
        )
    )
  }
' "${files[@]}"
