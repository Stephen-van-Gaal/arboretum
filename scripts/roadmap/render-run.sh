#!/usr/bin/env bash
# owner: roadmap
# Render the /roadmap run daily view from current GH state.
#
# Two output modes:
#   (default)    full §7c-style view (Done / Now / Next / Later / Slack + Recommend)
#   --condensed  compact ~5-line orientation block for SessionStart hook injection
#
# Inputs (one of):
#   (default)            call gh against current repo
#   --board-file <path>  read issue JSON from file (test mode)
#   --closed-file <path> read recently-closed issue JSON from file (test mode)

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: requires bash. Run: bash $0" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

condensed=false
board_file=""
closed_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --condensed)    condensed=true; shift ;;
    --board-file)   board_file="$2"; shift 2 ;;
    --closed-file)  closed_file="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Config guard and live-mode setup (skipped in --board-file test mode)
wip_limit=1
nag_output=""
if [ -z "$board_file" ]; then
  CONFIG="$(roadmap_config_path)" || true
  [ -z "$CONFIG" ] && exit 0

  wip_limit=$(roadmap_config_get wip_limit 2>/dev/null || echo 1)

  # Run nag before gh guard so strategic-review-due surfaces even offline.
  nag_output="$(bash "$SCRIPT_DIR/nag.sh" 2>/dev/null || true)"
fi

# Load board (open issues)
if [ -n "$board_file" ]; then
  open_json="$(cat "$board_file")"
else
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    [ -n "$nag_output" ] && printf '%s\n' "$nag_output"
    exit 0
  fi
  open_json="$(gh issue list --state open --limit 200 \
    --json number,title,labels,updatedAt,milestone 2>/dev/null || echo '[]')"
fi

# Load closed (last 7d) — soft-fail if not available
if [ -n "$closed_file" ]; then
  closed_json="$(cat "$closed_file")"
elif [ -z "$board_file" ]; then
  closed_json="$(gh issue list --state closed --limit 50 \
    --json number,title,closedAt --search "closed:>$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)" 2>/dev/null || echo '[]')"
else
  closed_json='[]'
fi

# WIP detection: count branches with feat/, fix/, docs/, chore/ prefixes plus worktrees
wip_count=0
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  wip_count="$(git worktree list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
fi

# Group open issues by horizon, plus slack lane
now_list=$(echo "$open_json" | jq -r '
  [.[] | select(any(.labels[]; .name == "horizon:now"))]
  | sort_by(.number)
  | .[] | "\(.number)\t\(.title)"')

next_list=$(echo "$open_json" | jq -r '
  [.[] | select(any(.labels[]; .name == "horizon:next"))]
  | sort_by(.number)
  | .[] | "\(.number)\t\(.title)"')

later_list=$(echo "$open_json" | jq -r '
  [.[] | select(any(.labels[]; .name == "horizon:later"))]
  | sort_by(.number) | reverse
  | .[] | "\(.number)\t\(.title)"')

slack_list=$(echo "$open_json" | jq -r '
  [.[] | select(any(.labels[]; .name == "type:docs" or .name == "type:chore"))]
  | sort_by(.number) | reverse
  | .[] | "\(.number)\t\(.title)\t\(.labels | map(select(.name == "type:docs" or .name == "type:chore")) | first.name)"')

untriaged_count=$(echo "$open_json" | jq '
  [.[] | select(any(.labels[]; .name | startswith("horizon:")) | not)] | length')

agent_ready_list=$(echo "$open_json" | jq -r '
  [.[] | select(any(.labels[]; .name == "agent-ready"))]
  | sort_by(.number)
  | .[] | "\(.number)\t\(.title)"')

# Counts for header (avoid grep -c || echo 0 — produces "0\n0" when grep exits 1)
total_open=$(echo "$open_json" | jq 'length')
count_lines() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }
now_count=$(count_lines "$now_list")
next_count=$(count_lines "$next_list")
later_count=$(count_lines "$later_list")

# ── Condensed mode (SessionStart hook block) ──────────────────────────
if $condensed; then
  printf '[roadmap] %d open · %d now · %d next · %d later · %d untriaged · WIP: %d\n' \
    "$total_open" "$now_count" "$next_count" "$later_count" "$untriaged_count" "$wip_count"

  if [ "$now_count" -gt 0 ]; then
    printf '\nNOW:\n'
    printf '%s\n' "$now_list" | head -3 | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue
      printf '  #%s  %s\n' "$n" "$t"
    done
  fi

  if [ -n "$agent_ready_list" ]; then
    printf '\n★ agent-ready:\n'
    printf '%s\n' "$agent_ready_list" | head -3 | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue
      printf '  #%s  %s\n' "$n" "$t"
    done
  fi

  if [ "$untriaged_count" -ge 5 ]; then
    printf '\n  → /roadmap maintain has %d untriaged\n' "$untriaged_count"
  fi
  exit 0
fi

# ── Full mode (interactive view) ──────────────────────────────────────
sep="═══════════════════════════════════════════════════════════════════════"
echo "$sep"
printf '  Roadmap — %d open · %d now · %d next · %d later · WIP: %d/%d\n' \
  "$total_open" "$now_count" "$next_count" "$later_count" "$wip_count" "$wip_limit"
echo "$sep"

# DONE
done_count=$(echo "$closed_json" | jq 'length')
if [ "$done_count" -gt 0 ]; then
  echo
  echo "DONE  (last 7 days)"
  echo "$closed_json" | jq -r '.[] | "  #\(.number)  \(.title)  \(.closedAt[0:10])"' | head -5
fi

# NOW
echo
printf 'NOW  (%d/%d WIP)\n' "$wip_count" "$wip_limit"
if [ -n "$now_list" ]; then
  printf '%s\n' "$now_list" | while IFS=$'\t' read -r n t; do
    [ -z "$n" ] && continue
    printf '  #%s  %s\n' "$n" "$t"
  done
else
  echo "  (nothing in flight)"
fi

# NEXT
echo
printf 'NEXT\n'
if [ -n "$next_list" ]; then
  printf '%s\n' "$next_list" | head -10 | while IFS=$'\t' read -r n t; do
    [ -z "$n" ] && continue
    printf '  #%s  %s\n' "$n" "$t"
  done
else
  echo "  (queue empty — run /roadmap maintain to surface candidates)"
fi

# AGENT-READY (called out separately because they're delegation-ready)
if [ -n "$agent_ready_list" ]; then
  echo
  echo 'AGENT-READY (parallel pickup via /start --agent <n>)'
  printf '%s\n' "$agent_ready_list" | while IFS=$'\t' read -r n t; do
    [ -z "$n" ] && continue
    printf '  ★ #%s  %s\n' "$n" "$t"
  done
fi

# LATER (top 5 only)
if [ "$later_count" -gt 0 ]; then
  echo
  printf 'LATER  (top 5 of %d)\n' "$later_count"
  printf '%s\n' "$later_list" | head -5 | while IFS=$'\t' read -r n t; do
    [ -z "$n" ] && continue
    printf '  #%s  %s\n' "$n" "$t"
  done
fi

# SLACK lane
echo
echo 'SLACK  (parallel-safe alongside WIP)'
if [ "$untriaged_count" -ge 3 ]; then
  printf '  /roadmap maintain  ← %d untriaged\n' "$untriaged_count"
fi
if [ -n "$slack_list" ]; then
  printf '%s\n' "$slack_list" | head -3 | while IFS=$'\t' read -r n t l; do
    [ -z "$n" ] && continue
    printf '  #%s  %s  [%s]\n' "$n" "$t" "$l"
  done
fi

# RECOMMEND
# Order matters: most-specific situation wins.
echo
echo "$sep"
echo "RECOMMEND"
if [ "$wip_count" -ge 1 ] && [ "$now_count" -eq 0 ] && [ "$total_open" -gt 0 ]; then
  # Worktree exists but no horizon:now — common during instantiation gap
  echo "  • You have a worktree but no horizon:now issue. Identify the in-flight"
  echo "    issue and apply horizon:now (or run /roadmap maintain to triage)."
elif [ "$wip_count" -ge 1 ] && [ "$now_count" -ge 1 ]; then
  echo "  • You have work in flight — finish before starting another."
elif [ "$now_count" -gt 0 ]; then
  echo "  • Pick up a horizon:now item to get started."
elif [ "$next_count" -gt 0 ]; then
  echo "  • No horizon:now items — promote from NEXT or run /roadmap maintain."
elif [ "$untriaged_count" -ge 3 ]; then
  # The "all horizons empty but board has issues" case — most users will hit
  # this immediately after install. Don't tell them to capture more work.
  echo "  • $untriaged_count untriaged issues — run /roadmap maintain to triage them"
  echo "    (Phase 2; for now, manually apply horizon:* labels)."
elif [ "$total_open" -eq 0 ]; then
  echo "  • Empty board — capture new work with /idea."
else
  echo "  • Board has open issues but none in horizon:now/next/later — triage needed."
fi
[ -n "$agent_ready_list" ] && echo "  • ★ agent-ready items can be delegated to a subagent in parallel."
echo "$sep"

if [ -n "$nag_output" ]; then
  printf '\n%s\n' "$nag_output"
fi
