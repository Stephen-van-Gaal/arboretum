#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# Classify open issues into /roadmap maintain action buckets.
#
# Read-only. Cross-references open issues against recently-merged PRs and
# issue-body heuristics, assigning each issue exactly one bucket by a fixed
# precedence. Mirrors audit-board.sh: pure classification, no mutation.
#
# Inputs (live mode calls the configured tracker adapter; test mode reads files):
#   --issues-file <path>   open item JSON (tracker issue list shape)
#   --prs-file <path>      merged PR JSON (tracker PR list shape)
#   --as-of <YYYY-MM-DD>   override "today" for deterministic tests
#
# Buckets (precedence — first match wins):
#   auto_close     closing-keyword PR (<=60d) OR all body checkboxes ticked
#   soft_resolved  PR (<=60d) mentions the issue without a closing keyword
#   agent_ready_invalidated  agent-ready label whose body changed since
#                            verification, which has no marker, or whose
#                            only marker comment is from an untrusted author
#                            (authorAssociation not OWNER/MEMBER/COLLABORATOR)
#   agent_ready_stale        agent-ready verified >7d ago, still unused
#   orphan         updated >90d ago
#   untriaged      no horizon:* label
#   unshaped_next  horizon:next but body lacks a Markdown ## or HTML <h2> heading or is <200 chars
#   healthy        none of the above
#
# Output JSON:
#   { "buckets": { "<bucket>": [ {number,title,evidence}, ... ], ... },
#     "counts":  { "<bucket>": N, ... } }

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: requires bash. Run: bash $0" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

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
  PROJECT_ROOT="$(roadmap_project_root)"
  export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_ROOT")}"
  roadmap_require_backend "$ROADMAP_BACKEND" || exit 1
  issues="$(roadmap_tracker_issue_list --state open --limit 200 \
    --json number,title,body,labels,createdAt,updatedAt,comments)"
fi

# Load merged PRs (live: most recent 200; jq filters to the 60-day window)
if [ -n "$prs_file" ]; then
  [ -f "$prs_file" ] || { echo "Not a file: $prs_file" >&2; exit 1; }
  prs="$(cat "$prs_file")"
else
  prs="$(roadmap_tracker_pr_list --state merged --limit 200 \
    --json number,title,body,mergedAt)"
fi

# --- Decay pre-pass (design D5) -------------------------------------------
# jq cannot compute SHA-256. For each open issue carrying `agent-ready` we
# hash the current body and extract the latest `agent-prep:verified` marker
# here, in bash, from the already-fetched $issues JSON (no extra tracker calls).
# The classifier consumes the result as $agent_ready.
agent_ready='{}'
while IFS= read -r n; do
  [ -z "$n" ] && continue
  body="$(printf '%s' "$issues" | jq -r --argjson n "$n" \
    '.[] | select(.number == $n) | .body // ""')"
  current_sha="$(printf '%s' "$body" | shasum -a 256 | cut -c1-12)"
  marker="$(printf '%s' "$issues" | jq -r --argjson n "$n" \
    '.[] | select(.number == $n)
     | (if (.comments | type) == "array" then .comments else [] end)
     | map(select(
         ((.body // "") | test("agent-prep:verified")) and
         (.authorAssociation // "" | IN("OWNER","MEMBER","COLLABORATOR"))
       ))
     | sort_by(.createdAt) | last | (.body // "")')"
  m_date="$(printf '%s' "$marker" | sed -nE \
    's/.*agent-prep:verified[[:space:]]+date=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
  # Reject impossible calendar dates so the jq classifier never calls
  # fromdate on garbage and crashes the whole scan (Codex P2).
  if [ -n "$m_date" ] && ! [[ "$m_date" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then
    m_date=""
  fi
  m_sha="$(printf '%s' "$marker" | sed -nE \
    's/.*body-sha=([0-9a-f]{12}).*/\1/p')"
  agent_ready="$(printf '%s' "$agent_ready" | jq \
    --argjson n "$n" --arg cs "$current_sha" --arg md "$m_date" --arg ms "$m_sha" \
    '. + { ($n | tostring): { currentSha: $cs, markerDate: $md, markerSha: $ms,
                              hasMarker: (($md | length) > 0) } }')"
done < <(printf '%s' "$issues" | jq -r \
  '.[] | select([.labels[].name] | index("agent-ready")) | .number')
# --------------------------------------------------------------------------

jq -n \
  --argjson issues "$issues" \
  --argjson prs "$prs" \
  --arg asof "$as_of" \
  --argjson agent_ready "$agent_ready" '
  def days_since(d):
    (($asof + "T00:00:00Z" | fromdate) - (d | fromdate)) / 86400 | floor;

  # Merged PRs within the 60-day window.
  ($prs | map(select(days_since(.mergedAt) <= 60))) as $recent_prs

  | ($issues | map(
      . as $iss
      | ($iss.number) as $n
      | ($iss.body // "") as $body
      | ([$iss.labels[].name]) as $labels
      | ($body | [match("(?im)^[[:space:]]*[-*][[:space:]]+\\[[xX]\\]"; "g")] | length) as $done_markdown_boxes
      | ($body | [match("(?im)^[[:space:]]*[-*][[:space:]]+\\[ \\]"; "g")] | length) as $open_markdown_boxes
      | ($body | [match("(?i)<li[^>]*>[[:space:]]*\\[[xX]\\]"; "g")] | length) as $done_html_boxes
      | ($body | [match("(?i)<li[^>]*>[[:space:]]*\\[[[:space:]]\\]"; "g")] | length) as $open_html_boxes
      | ($done_markdown_boxes + $done_html_boxes) as $done_boxes
      | ($open_markdown_boxes + $open_html_boxes) as $open_boxes
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
      | ((($body | test("(?m)^##[[:space:]]")) or ($body | test("(?i)<h2([[:space:]>])"))) and (($body | length) >= 200)) as $shaped
      | (([$iss.labels[].name] | index("agent-ready")) != null) as $is_ar
      | ($agent_ready[($n | tostring)]) as $ar
      | (
          if $is_ar and ($ar != null) then
            if   ($ar.hasMarker | not)             then "invalidated"
            elif ($ar.markerSha != $ar.currentSha) then "invalidated"
            elif (days_since($ar.markerDate + "T00:00:00Z") > 7) then "stale"
            else "fresh" end
          else "none" end
        ) as $ar_state
      | {
          number: $n,
          title: $iss.title,
          bucket: (
            if   ($closing_ref or $all_checked)   then "auto_close"
            elif $partial_ref                     then "soft_resolved"
            elif ($ar_state == "invalidated")     then "agent_ready_invalidated"
            elif ($ar_state == "stale")           then "agent_ready_stale"
            elif ($updated_d > 90)                then "orphan"
            elif ($has_horizon | not)             then "untriaged"
            elif ($has_next and ($shaped | not))  then "unshaped_next"
            else "healthy" end
          ),
          # Evidence strings must use only controlled fields (issue/PR numbers, dates, day counts).
          # Never embed untrusted .title or .body content — evidence flows verbatim into tracker comment bodies in maintain-apply.sh.
          evidence: (
            if   $closing_ref then "Merged PR #\($closing_prs[0].number) references this with a closing keyword"
            elif $all_checked then "All \($done_boxes) acceptance checkbox(es) ticked, none left open"
            elif $partial_ref then "Merged PR #\($mention_prs[0].number) mentions this without a closing keyword"
            elif ($ar_state == "invalidated") then (
              if ($ar.hasMarker | not)
              then "agent-ready label present but no agent-prep verification comment from a trusted author found"
              else "Issue body edited since agent-ready was verified on \($ar.markerDate) (body-sha mismatch)" end)
            elif ($ar_state == "stale") then
              "agent-ready verified \(days_since($ar.markerDate + "T00:00:00Z")) days ago, unused — past the 7-day window"
            elif ($updated_d > 90) then "Open \($updated_d) days; no merged-PR reference, no recent activity"
            elif ($has_horizon | not) then "No horizon:* label — needs triage"
            elif ($has_next and ($shaped | not)) then "horizon:next but body lacks shape (needs a Markdown ## or HTML <h2> heading and >=200 chars)"
            else "" end
          )
        }
    )) as $classified

  | {
      buckets: (
        reduce ["auto_close","soft_resolved","agent_ready_invalidated","agent_ready_stale","orphan","untriaged","unshaped_next"][] as $b
          ({}; . + { ($b): [ $classified[] | select(.bucket == $b) | {number,title,evidence} ] })
      ),
      counts: (
        reduce ["auto_close","soft_resolved","agent_ready_invalidated","agent_ready_stale","orphan","untriaged","unshaped_next","healthy"][] as $b
          ({}; . + { ($b): ([ $classified[] | select(.bucket == $b) ] | length) })
      )
    }
'
