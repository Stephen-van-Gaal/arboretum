#!/usr/bin/env bash
# owner: roadmap
# Time-based nag computation for the roadmap system.
# Called by build-orientation.sh after the orientation block.
# Outputs [nag] lines to stdout; no output = no nags due.
# Fail-silent contract: exits 0 always; never blocks session start.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

CONFIG="$(roadmap_config_path 2>/dev/null || true)"
[ -z "$CONFIG" ] && exit 0

roadmap_pulse_bootstrap 2>/dev/null || true

PULSE="$(roadmap_pulse_path 2>/dev/null || true)"
[ -z "$PULSE" ] || [ ! -f "$PULSE" ] && exit 0

# ── Date helpers ──────────────────────────────────────────────────────

# Days elapsed since the date portion of an ISO8601 timestamp.
# Returns 999 for empty/null so overdue conditions trigger on missing data.
_days_since() {
  local ts="${1:-}"
  if [ -z "$ts" ] || [ "$ts" = "null" ]; then echo 999; return; fi
  python3 - "${ts:0:10}" <<'PYEOF' 2>/dev/null || echo 999
from datetime import date, datetime, timezone
import sys
d = date.fromisoformat(sys.argv[1])
print((datetime.now(timezone.utc).date() - d).days)
PYEOF
}

# True (exits 0) if this nag fired today (per-day throttle).
_throttled_day() {
  local name="$1"
  local last
  last="$(roadmap_pulse_get_nag "$name" 2>/dev/null || true)"
  [ -z "$last" ] && return 1
  [ "${last:0:10}" = "$(date -u +%Y-%m-%d)" ]
}

# True (exits 0) if this nag fired within the last 7 days (weekly throttle).
_throttled_week() {
  local name="$1"
  local last
  last="$(roadmap_pulse_get_nag "$name" 2>/dev/null || true)"
  [ -z "$last" ] && return 1
  local days
  days="$(_days_since "$last")"
  [ "$days" -lt 7 ]
}

# Emit a nag line and record its name for the post-run pulse update.
FIRED_NAGS=""
_fire() {
  local name="$1" msg="$2"
  printf '[nag] %s\n' "$msg"
  FIRED_NAGS="$FIRED_NAGS $name"
}

# ── Nag 1: strategic-review-due (weekly, no tracker required) ─────────
# Fires when now - last_reviewed >= review_cadence_weeks * 7 days.

if ! _throttled_week "strategic-review-due" 2>/dev/null; then
  last_reviewed="$(roadmap_config_get last_reviewed 2>/dev/null || true)"
  cadence="$(roadmap_config_get review_cadence_weeks 2>/dev/null || true)"
  cadence="${cadence:-12}"
  if [ -n "$last_reviewed" ] && [ "$last_reviewed" != "null" ]; then
    days_since_review="$(_days_since "${last_reviewed}T00:00:00Z")"
    threshold=$(( cadence * 7 ))
    if [ "$days_since_review" -ge "$threshold" ]; then
      overdue=$(( days_since_review - threshold ))
      _fire "strategic-review-due" \
        "Strategic review overdue by ${overdue}d (last: ${last_reviewed}, cadence: ${cadence}w). Run '/roadmap revise'."
    fi
  fi
fi

# ── Nag 2: maintain-overdue (daily; needs tracker for untriaged count) ─
# Fires when last_maintain_run is >7 days ago AND untriaged >= 3.
# Silent when the tracker is unavailable — untriaged count cannot be verified.

if ! _throttled_day "maintain-overdue" 2>/dev/null; then
  if roadmap_require_backend >/dev/null 2>&1; then
    last_maintain="$(roadmap_pulse_get_field "last_maintain_run" 2>/dev/null || true)"
    days_since_maintain="$(_days_since "${last_maintain:-}")"
    if [ "$days_since_maintain" -ge 7 ]; then
      untriaged="$(roadmap_tracker_issue_list --search "no:label is:open" --limit 200 \
        --json number --jq 'length' 2>/dev/null || echo 0)"
      if [ "$untriaged" -ge 3 ]; then
        _fire "maintain-overdue" \
          "Maintain last run ${days_since_maintain}d ago — ${untriaged} untriaged issues. Run '/roadmap maintain'."
      fi
    fi
  fi
fi

# ── Nag 3: stale-flagged-today (daily; needs tracker) ─────────────────
# Fires when any provisionally-stale issues exist.

if ! _throttled_day "stale-flagged-today" 2>/dev/null; then
  if roadmap_require_backend >/dev/null 2>&1; then
    stale_count="$(roadmap_tracker_issue_list --label "provisionally-stale" --state open \
      --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)"
    if [ "$stale_count" -ge 1 ]; then
      _fire "stale-flagged-today" \
        "${stale_count} provisionally-stale issue(s) need review. Run '/roadmap maintain'."
    fi
  fi
fi

# ── Nag 4: agent-ready-while-WIP-full (daily; needs tracker) ──────────
# Fires when WIP is at or above wip_limit AND agent-ready issues exist.

if ! _throttled_day "agent-ready-while-WIP-full" 2>/dev/null; then
  if roadmap_require_backend >/dev/null 2>&1; then
    wip_limit="$(roadmap_config_get wip_limit 2>/dev/null || true)"
    wip_limit="${wip_limit:-1}"
    wip_count="$(roadmap_tracker_issue_list --label "horizon:now" --state open --limit 200 \
      --json number --jq 'length' 2>/dev/null || echo 0)"
    agent_ready="$(roadmap_tracker_issue_list --label "agent-ready" --state open --limit 200 \
      --json number --jq 'length' 2>/dev/null || echo 0)"
    if [ "$wip_count" -ge "$wip_limit" ] && [ "$agent_ready" -ge 1 ]; then
      _fire "agent-ready-while-WIP-full" \
        "WIP full (${wip_count}/${wip_limit}) but ${agent_ready} agent-ready issue(s) waiting. Consider subagent pickup."
    fi
  fi
fi

# ── Nag 5: profile-graduation-lean (weekly; needs tracker for count) ──
# Fires when profile=minimal and open issue count >= 20.

if ! _throttled_week "profile-graduation-lean" 2>/dev/null; then
  profile="$(roadmap_config_get profile 2>/dev/null || true)"
  if [ "${profile:-minimal}" = "minimal" ]; then
    if roadmap_require_backend >/dev/null 2>&1; then
      open_count="$(roadmap_tracker_issue_list --state open --limit 200 \
        --json number --jq 'length' 2>/dev/null || echo 0)"
      if [ "$open_count" -ge 20 ]; then
        _fire "profile-graduation-lean" \
          "Project has ${open_count} open issues on Minimal profile. Consider upgrading: run '/roadmap instantiate' and choose Lean."
      fi
    fi
  fi
fi

# ── Record fire timestamps (batch, after all output) ──────────────────

for _nag in $FIRED_NAGS; do
  roadmap_pulse_set_nag_fired "$_nag" 2>/dev/null || true
done

exit 0
