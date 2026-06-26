#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# Deterministic ranked render for /roadmap score.
#   --cache <file>    scored-issues cache (required)
#   --issues <file>   issues JSON for title join (optional; titles scrubbed in render path)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cache=""; issues=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cache)  cache="$2";  shift 2 ;;
    --issues) issues="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "score-render: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$cache" ]  || { echo "score-render: --cache is required" >&2; exit 2; }
[ -f "$cache" ]  || { echo "score-render: cache file not found: $cache" >&2; exit 2; }

cache_json="$(cat "$cache")"
echo "ROADMAP SCORE — ranked"
if [ -n "$issues" ] && [ -f "$issues" ]; then
  # Titles come fresh from gh (raw passthrough) — scrub control chars here in the render path.
  printf '%s' "$cache_json" | jq -r --slurpfile iss "$issues" '
    ($iss[0] | map({key: (.number|tostring), value: .title}) | from_entries) as $titles
    | to_entries
    | sort_by(({"high":0,"medium":1,"low":2}[.value.value]//3),
              ({"none":0,"one-decision":1,"spec":2}[.value.blocker]//3),
              (.key | tonumber))
    | .[] | "#\(.key) [\(.value.value)/\(.value.complexity)/\(.value.blocker)] \(.value.disposition)\(
              ($titles[.key] // "") | if . != "" then " \(.)" else "" end)"' \
  | scrub_control_chars
else
  printf '%s' "$cache_json" | jq -r '
    to_entries
    | sort_by(({"high":0,"medium":1,"low":2}[.value.value]//3),
              ({"none":0,"one-decision":1,"spec":2}[.value.blocker]//3),
              (.key | tonumber))
    | .[] | "#\(.key) [\(.value.value)/\(.value.complexity)/\(.value.blocker)] \(.value.disposition)"'
fi
echo; echo "★ AGENT-READY"
bash "$SCRIPT_DIR/score-cache.sh" --agent-ready-list --cache "$cache" | sed 's/^/  #/'
echo; echo "⚑ COMBINE/DELETE"
printf '%s' "$cache_json" | jq -r '
  to_entries[] | select(.value.disposition=="combine" or .value.disposition=="delete")
  | "  #\(.key) → \(.value.disposition)\(if .value.disposition=="combine" then " (anchor #\(.value.anchor))" else "" end)"'
