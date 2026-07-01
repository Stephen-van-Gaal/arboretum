#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# read-autonomy-grant.sh — Resolve the current autonomy grant for a tracker
# issue (#915 slice 6 / #922 — grant carriage on the pipeline-state seam).
#
# The grant is carried on the existing seam, no new transport: the exclusive
# `autonomy:*` tracker label is the AUTHORITATIVE current grant (last-writer-
# wins, set at the design→build grant gate), and the journey-log `grant=<tier>`
# entries written by log-stage.sh are the audit trail. Downstream drivers call
# this to learn their autonomy boundary.
#
# Emits exactly one line:
#   grant=<pause-at-land|pause-at-merge|auto-merge|design-only>
# where `design-only` is the absence of any autonomy:* label (today's default).
#
# Usage: read-autonomy-grant.sh <issue-number>
# Test hook: AUTONOMY_GRANT_LABELS_OVERRIDE — a whitespace/newline-separated
#   label list standing in for the issue's labels, bypassing the tracker call.
#
# Exit: 0 success; 1 bad args / tracker failure; 2 grant drift (more than one
#       autonomy:* label, or an autonomy:* value outside the closed vocabulary).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "read-autonomy-grant.sh requires bash" >&2; exit 1; }

ISSUE="${1:-}"
[ -n "$ISSUE" ] || { echo "read-autonomy-grant.sh: issue number required" >&2; echo "Usage: read-autonomy-grant.sh <issue-number>" >&2; exit 1; }

# ── Gather the issue's labels ───────────────────────────────────────
# Test/offline path: caller supplies the label set directly. Live path: read it
# from the configured roadmap backend (requires gh for backend=github).
if [ "${AUTONOMY_GRANT_LABELS_OVERRIDE+set}" = "set" ]; then
  LABELS="$AUTONOMY_GRANT_LABELS_OVERRIDE"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=roadmap/lib.sh
  source "$SCRIPT_DIR/roadmap/lib.sh"
  if ! LABELS_JSON=$(roadmap_tracker_issue_show "$ISSUE" --json labels 2>/dev/null); then
    echo "read-autonomy-grant.sh: could not read labels for issue #$ISSUE from the tracker" >&2
    exit 1
  fi
  # Labels may arrive as [{"name":"x"},...] or ["x",...] depending on backend.
  LABELS=$(printf '%s' "$LABELS_JSON" | jq -r '
    (.labels // .) | map(if type=="object" then .name else . end) | .[]' 2>/dev/null) \
    || { echo "read-autonomy-grant.sh: could not parse labels JSON for issue #$ISSUE" >&2; exit 1; }
fi

# ── Extract the autonomy:* token(s) ─────────────────────────────────
# Disable globbing around the intentional word-split of the label stream (the
# override is whitespace-separated, the live path newline-separated); a label
# carries no embedded whitespace, but without noglob a label containing a glob
# metacharacter could expand as a pathname pattern. Collect into a single
# space-joined string and count as we go.
set -f
AUTONOMY_LABELS=""
COUNT=0
for _lbl in $LABELS; do
  case "$_lbl" in
    autonomy:*)
      AUTONOMY_LABELS="${AUTONOMY_LABELS:+$AUTONOMY_LABELS }$_lbl"
      COUNT=$((COUNT + 1))
      ;;
  esac
done
set +f

if [ "$COUNT" -eq 0 ]; then
  echo "grant=design-only"
  exit 0
fi

if [ "$COUNT" -gt 1 ]; then
  echo "read-autonomy-grant.sh: issue #$ISSUE carries more than one autonomy:* label — the grant label is exclusive (last-writer-wins); this is drift: $AUTONOMY_LABELS" >&2
  exit 2
fi

TIER="${AUTONOMY_LABELS#autonomy:}"
case "$TIER" in
  pause-at-land|pause-at-merge|auto-merge)
    echo "grant=$TIER"
    ;;
  *)
    echo "read-autonomy-grant.sh: issue #$ISSUE carries an autonomy:* label outside the closed vocabulary (pause-at-land|pause-at-merge|auto-merge): autonomy:$TIER" >&2
    exit 2
    ;;
esac
