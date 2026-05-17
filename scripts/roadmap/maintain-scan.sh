#!/usr/bin/env bash
# owner: roadmap
# Classify open issues into /roadmap maintain action buckets.
#
# Read-only. Cross-references open issues against recently-merged PRs and
# issue-body heuristics, assigning each issue exactly one bucket by a fixed
# precedence. Mirrors audit-board.sh: pure classification, no mutation.
#
# Inputs (live mode calls gh; test mode reads files):
#   --issues-file <path>   open-issue JSON (gh issue list --json ...)
#   --prs-file <path>      merged-PR JSON (gh pr list --state merged --json ...)
#   --as-of <YYYY-MM-DD>   override "today" for deterministic tests
#
# Buckets (precedence — first match wins):
#   auto_close     closing-keyword PR (<=60d) OR all body checkboxes ticked
#   soft_resolved  PR (<=60d) mentions the issue without a closing keyword
#   orphan         updated >90d ago
#   untriaged      no horizon:* label
#   unshaped_next  horizon:next but body lacks a ## heading or is <200 chars
#   healthy        none of the above
#
# Output JSON:
#   { "buckets": { "<bucket>": [ {number,title,evidence}, ... ], ... },
#     "counts":  { "<bucket>": N, ... } }

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: requires bash. Run: bash $0" >&2; exit 1
fi

issues_file=""
prs_file=""
as_of="$(date -u +%Y-%m-%d)"

while [ $# -gt 0 ]; do
  case "$1" in
    --issues-file) issues_file="$2"; shift 2 ;;
    --prs-file)    prs_file="$2";    shift 2 ;;
    --as-of)       as_of="$2";       shift 2 ;;
    -h|--help)     sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Load open issues
if [ -n "$issues_file" ]; then
  [ -f "$issues_file" ] || { echo "Not a file: $issues_file" >&2; exit 1; }
  issues="$(cat "$issues_file")"
else
  command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 1; }
  issues="$(gh issue list --state open --limit 200 \
    --json number,title,body,labels,createdAt,updatedAt)"
fi

# Load merged PRs (live: most recent 200; jq filters to the 60-day window)
if [ -n "$prs_file" ]; then
  [ -f "$prs_file" ] || { echo "Not a file: $prs_file" >&2; exit 1; }
  prs="$(cat "$prs_file")"
else
  prs="$(gh pr list --state merged --limit 200 \
    --json number,title,body,mergedAt)"
fi

jq -n \
  --argjson issues "$issues" \
  --argjson prs "$prs" \
  --arg asof "$as_of" '
  def days_since(d):
    (($asof + "T00:00:00Z" | fromdate) - (d | fromdate)) / 86400 | floor;

  # Merged PRs within the 60-day window.
  ($prs | map(select(days_since(.mergedAt) <= 60))) as $recent_prs

  | ($issues | map(
      . as $iss
      | ($iss.number) as $n
      | ($iss.body // "") as $body
      | ([$iss.labels[].name]) as $labels
      | ($body | [match("(?im)^[[:space:]]*[-*][[:space:]]+\\[[xX]\\]"; "g")] | length) as $done_boxes
      | ($body | [match("(?im)^[[:space:]]*[-*][[:space:]]+\\[ \\]"; "g")] | length) as $open_boxes
      | (($done_boxes >= 1) and ($open_boxes == 0)) as $all_checked
      | ($recent_prs | map(select(
          (((.body // "") + " " + (.title // ""))) | test("(?i)\\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+#" + ($n|tostring) + "\\b")
        ))) as $closing_prs
      | ($recent_prs | map(select(
          (((.body // "") + " " + (.title // ""))) | test("#" + ($n|tostring) + "\\b")
        ))) as $mention_prs
      | (($closing_prs | length) > 0) as $closing_ref
      | ((($mention_prs | length) > 0) and ($closing_ref | not)) as $partial_ref
      | (days_since($iss.updatedAt)) as $updated_d
      | (any($labels[]; startswith("horizon:"))) as $has_horizon
      | (any($labels[]; . == "horizon:next")) as $has_next
      | (($body | test("(?m)^##[[:space:]]")) and (($body | length) >= 200)) as $shaped
      | {
          number: $n,
          title: $iss.title,
          bucket: (
            if   ($closing_ref or $all_checked)   then "auto_close"
            elif $partial_ref                     then "soft_resolved"
            elif ($updated_d > 90)                then "orphan"
            elif ($has_horizon | not)             then "untriaged"
            elif ($has_next and ($shaped | not))  then "unshaped_next"
            else "healthy" end
          ),
          evidence: (
            if   $closing_ref then "Merged PR #\($closing_prs[0].number) references this with a closing keyword"
            elif $all_checked then "All \($done_boxes) acceptance checkbox(es) ticked, none left open"
            elif $partial_ref then "Merged PR #\($mention_prs[0].number) mentions this without a closing keyword"
            elif ($updated_d > 90) then "Open \($updated_d) days; no merged-PR reference, no recent activity"
            elif ($has_horizon | not) then "No horizon:* label — needs triage"
            elif ($has_next and ($shaped | not)) then "horizon:next but body lacks shape (needs a ## heading and >=200 chars)"
            else "" end
          )
        }
    )) as $classified

  | {
      buckets: (
        reduce ["auto_close","soft_resolved","orphan","untriaged","unshaped_next"][] as $b
          ({}; . + { ($b): [ $classified[] | select(.bucket == $b) | {number,title,evidence} ] })
      ),
      counts: (
        reduce ["auto_close","soft_resolved","orphan","untriaged","unshaped_next","healthy"][] as $b
          ({}; . + { ($b): ([ $classified[] | select(.bucket == $b) ] | length) })
      )
    }
'
