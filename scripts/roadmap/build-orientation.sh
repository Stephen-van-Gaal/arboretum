#!/usr/bin/env bash
# owner: roadmap
# Produce the orientation block for /roadmap run and the SessionStart hook.
# Exits 0 with no output if roadmap.config.yaml is absent (so the hook can
# safely call this on every project).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CONFIG="$(roadmap_config_path)" || true
[ -z "$CONFIG" ] && exit 0
PROJECT_ROOT="$(roadmap_project_root)"
export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_ROOT")}"

# Run nag machinery before the tracker guard so strategic-review-due
# (tracker-independent) surfaces even when the tracker is unavailable.
NAG_OUTPUT="$(bash "$SCRIPT_DIR/nag.sh" 2>/dev/null || true)"

if ! roadmap_require_backend "$ROADMAP_BACKEND" >/dev/null 2>&1; then
  # No tracker: orientation unavailable, but nags still surface.
  [ -n "$NAG_OUTPUT" ] && printf '%s\n' "$NAG_OUTPUT"
  exit 0
fi

# Counts — use --limit 200 so we don't silently undercount on active repos.
NOW_COUNT=$(roadmap_tracker_issue_list --label "horizon:now" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
NEXT_COUNT=$(roadmap_tracker_issue_list --label "horizon:next" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
UNTRIAGED_COUNT=$(roadmap_tracker_issue_list --search "no:label is:open" --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
AGENT_READY_COUNT=$(roadmap_tracker_issue_list --label "agent-ready" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)

# Top NEXT (up to 3, most recently updated)
TOP_NEXT=$(roadmap_tracker_issue_list --label "horizon:next" --state open --limit 3 \
  --json number,title --jq '.[] | "  #\(.number) — \(.title)"' 2>/dev/null || true)

# Current branch — informational
BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

cat <<EOF
[Roadmap] horizon:now=$NOW_COUNT  horizon:next=$NEXT_COUNT  untriaged=$UNTRIAGED_COUNT  agent-ready=$AGENT_READY_COUNT
  Branch: $BRANCH
EOF

if [ -n "$TOP_NEXT" ]; then
  printf '  Top NEXT:\n%s\n' "$TOP_NEXT"
fi

# Append nags after orientation when the tracker is available.
if [ -n "$NAG_OUTPUT" ]; then
  printf '\n%s\n' "$NAG_OUTPUT"
fi
