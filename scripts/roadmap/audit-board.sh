#!/usr/bin/env bash
# owner: roadmap
# Categorize open issues into buckets for /roadmap run.
#
# Inputs (one of):
#   --board-file <path>   read issue JSON from file (test mode)
#   (default)             call the configured tracker backend
#
# Optional:
#   --as-of <YYYY-MM-DD>  override "today" for deterministic tests
#
# Output JSON shape:
#   {
#     "issues": { "<n>": "<bucket>", ... },
#     "by_bucket": { "<bucket>": [<n>, ...], ... },
#     "counts": { "<bucket>": N, ... }
#   }
#
# Buckets (MVP — Phase 1, no Epic distinction):
#   active        — has horizon:now AND updated in last 14d (in flight)
#   well_scoped   — has type:* + horizon:* AND not blocked AND not active
#   inbox         — created in last 7d AND no horizon:* label
#   speculative   — no horizon:* AND no activity in 60+ days
#   other         — doesn't fit above (e.g., blocked, partial labeling, stale-but-themed)
#
# Rule precedence (top wins):
#   blocked → other
#   inbox check (fresh + no horizon)
#   active check (horizon:now + recent)
#   well_scoped check (type + horizon, not blocked, not active)
#   speculative check (no horizon + stale)
#   else → other

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: requires bash. Run: bash $0" >&2; exit 1
fi

board_file=""
as_of="$(date -u +%Y-%m-%d)"

while [ $# -gt 0 ]; do
  case "$1" in
    --board-file) board_file="$2"; shift 2 ;;
    --as-of)      as_of="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Load board state
if [ -n "$board_file" ]; then
  [ -f "$board_file" ] || { echo "Not a file: $board_file" >&2; exit 1; }
  board="$(cat "$board_file")"
else
  roadmap_require_backend || exit 1
  board="$(roadmap_tracker_issue_list --state open --limit 200 \
    --json number,title,labels,createdAt,updatedAt,comments,milestone)"
fi

# Categorize via jq.
# We compute days-since for created/updated against $as_of,
# then apply bucket rules.
echo "$board" | jq --arg asof "$as_of" '
  def days_since(d):
    ((($asof + "T00:00:00Z") | fromdate) - (d | fromdate)) / 86400 | floor;

  map({
    number: .number,
    title: .title,
    labels: ([.labels[].name]),
    created_d: days_since(.createdAt),
    updated_d: days_since(.updatedAt),
    comments_n: (.comments // 0),
    has_type:    (any(.labels[]; .name | startswith("type:"))),
    has_horizon: (any(.labels[]; .name | startswith("horizon:"))),
    has_blocked: (any(.labels[]; .name == "blocked"))
  })
  | map(. + {
      has_horizon_now: (any(.labels[]; . == "horizon:now"))
    })
  | map(. + {
      bucket: (
        if (.has_blocked) then "other"
        elif (.created_d <= 7 and (.has_horizon | not)) then "inbox"
        elif (.has_horizon_now and .updated_d <= 14) then "active"
        elif (.has_type and .has_horizon) then "well_scoped"
        elif ((.has_horizon | not) and .updated_d > 60) then "speculative"
        else "other"
        end
      )
    })
  | {
      issues:    (map({key: (.number | tostring), value: .bucket}) | from_entries),
      by_bucket: (group_by(.bucket)
                  | map({key: .[0].bucket, value: [.[].number]})
                  | from_entries),
      counts:    (group_by(.bucket)
                  | map({key: .[0].bucket, value: length})
                  | from_entries)
    }
'
