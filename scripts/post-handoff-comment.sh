#!/usr/bin/env bash
# owner: session-handoff
# post-handoff-comment.sh — Post a marked session-handoff comment to a
# tracker issue. The HTML-comment marker lets refresh-next-cache.sh and
# humans find the latest handoff for an issue (design §4.1, §4.5).
#
# Usage: post-handoff-comment.sh <issue-number> <branch> <note-file> [project-dir]
#   <note-file> holds the human-approved note body (the → Next action
#   line + prose; no marker — this script prepends it).
#
# Exit: 0 posted; 1 bad args / tracker unavailable; 2 tracker call failed.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "post-handoff-comment.sh requires bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/roadmap/lib.sh
. "$SCRIPT_DIR/roadmap/lib.sh"

ISSUE="${1:?issue number required}"
BRANCH="${2:?branch required}"
NOTE_FILE="${3:?note file required}"
PROJECT_DIR="${4:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROADMAP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export ROADMAP_BACKEND

[ -f "$NOTE_FILE" ] || { echo "note file not found: $NOTE_FILE" >&2; exit 1; }
roadmap_require_backend "$ROADMAP_BACKEND" >/dev/null \
  || { echo "post-handoff-comment.sh cannot use backend '$ROADMAP_BACKEND'" >&2; exit 1; }

marker="<!-- arbo-handoff: ${BRANCH} $(date -u +%Y-%m-%dT%H:%M:%SZ) -->"

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  printf '%s\n' "$marker"
  printf '**Session handoff** · branch `%s` · %s\n\n' "$BRANCH" "$(date -u +%Y-%m-%d)"
  cat "$NOTE_FILE"
} > "$body"

( cd "$PROJECT_DIR" && roadmap_tracker_issue_comment "$ISSUE" --body-file "$body" ) \
  || { echo "tracker issue comment failed for #$ISSUE" >&2; exit 2; }
echo "Posted handoff comment to issue #$ISSUE."
exit 0
