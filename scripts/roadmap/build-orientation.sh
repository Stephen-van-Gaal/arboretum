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

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  # Fail silent per spec §6d — the hook must never block session start.
  exit 0
fi

# Counts — use --limit 200 so we don't silently undercount on active repos.
NOW_COUNT=$(gh issue list --label "horizon:now" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
NEXT_COUNT=$(gh issue list --label "horizon:next" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
UNTRIAGED_COUNT=$(gh issue list --search "no:label is:open" --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)
AGENT_READY_COUNT=$(gh issue list --label "agent-ready" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)

# Top NEXT (up to 3, most recently updated)
TOP_NEXT=$(gh issue list --label "horizon:next" --state open --limit 3 \
  --json number,title --jq '.[] | "  #\(.number) — \(.title)"' 2>/dev/null || true)

# Current branch — informational
BRANCH=$(git -C "$(roadmap_project_root)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

cat <<EOF
[Roadmap] horizon:now=$NOW_COUNT  horizon:next=$NEXT_COUNT  untriaged=$UNTRIAGED_COUNT  agent-ready=$AGENT_READY_COUNT
  Branch: $BRANCH
EOF

if [ -n "$TOP_NEXT" ]; then
  printf '  Top NEXT:\n%s\n' "$TOP_NEXT"
fi
