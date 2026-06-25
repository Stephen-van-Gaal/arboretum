#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# verify-agent-ready.sh — Validate that an issue's agent-ready label is fresh
# enough for /start's labelled fast lane to trust.
#
# Live:
#   bash scripts/verify-agent-ready.sh <issue-number>
#
# Test mode:
#   bash scripts/verify-agent-ready.sh --issue-file <issue-json> [--as-of YYYY-MM-DD]
set -euo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "verify-agent-ready.sh requires bash" >&2; exit 2; }

issue_file=""
issue_number=""
as_of="$(date -u +%Y-%m-%d)"

usage() {
  cat >&2 <<'EOF'
Usage: verify-agent-ready.sh <issue-number>
       verify-agent-ready.sh --issue-file <issue-json> [--as-of YYYY-MM-DD]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue-file) issue_file="${2:-}"; [ -n "$issue_file" ] || { usage; exit 2; }; shift 2 ;;
    --as-of)      as_of="${2:-}";      [ -n "$as_of" ]      || { usage; exit 2; }; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    --*)          echo "verify-agent-ready.sh: unknown arg: $1" >&2; exit 2 ;;
    *)
      [ -z "$issue_number" ] || { echo "verify-agent-ready.sh: multiple issue numbers supplied" >&2; exit 2; }
      issue_number="$1"
      shift
      ;;
  esac
done

if [ -n "$issue_file" ] && [ -n "$issue_number" ]; then
  echo "verify-agent-ready.sh: use either --issue-file or <issue-number>, not both" >&2
  exit 2
fi
[ -n "$issue_file" ] || [ -n "$issue_number" ] || { usage; exit 2; }

command -v jq >/dev/null 2>&1      || { echo "verify-agent-ready.sh: jq not found" >&2; exit 2; }
command -v shasum >/dev/null 2>&1  || { echo "verify-agent-ready.sh: shasum not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "verify-agent-ready.sh: python3 not found" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=roadmap/lib.sh
source "$SCRIPT_DIR/roadmap/lib.sh"

case "$as_of" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "verify-agent-ready.sh: --as-of must be YYYY-MM-DD, got: $as_of" >&2; exit 2 ;;
esac

if [ -n "$issue_file" ]; then
  [ -f "$issue_file" ] || { echo "verify-agent-ready.sh: issue file not found: $issue_file" >&2; exit 2; }
  issue_json="$(cat "$issue_file")"
else
  case "$issue_number" in
    ''|*[!0-9]*|0|0[0-9]*)
      echo "verify-agent-ready.sh: issue number must be a strictly positive integer, got: $issue_number" >&2
      exit 2
      ;;
  esac
  PROJECT_ROOT="$(roadmap_project_root)"
  export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_ROOT")}"
  roadmap_require_backend "$ROADMAP_BACKEND" || exit 2
  issue_json="$(roadmap_tracker_issue_show "$issue_number" --json number,title,body,labels,comments)"
fi

printf '%s' "$issue_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || { echo "verify-agent-ready.sh: issue JSON must be an object" >&2; exit 2; }

number="$(printf '%s' "$issue_json" | jq -r '.number // empty')"
case "$number" in
  ''|*[!0-9]*|0|0[0-9]*)
    echo "verify-agent-ready.sh: issue JSON missing positive integer .number" >&2
    exit 2
    ;;
esac

not_ready() {
  local reason="$1"
  echo "status=not-ready reason=$reason issue=$number" >&2
  exit 1
}

has_agent_ready="$(printf '%s' "$issue_json" | jq -r 'any(.labels[]?; .name == "agent-ready")')"
[ "$has_agent_ready" = "true" ] || not_ready "missing-agent-ready-label"

body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
current_sha="$(printf '%s' "$body" | shasum -a 256 | cut -c1-12)"

marker="$(printf '%s' "$issue_json" | jq -r '
  (if (.comments | type) == "array" then .comments else [] end)
  | map(select(
      ((.body // "") | test("agent-prep:verified")) and
      (.authorAssociation // "" | IN("OWNER","MEMBER","COLLABORATOR"))
    ))
  | sort_by(.createdAt)
  | last
  | (.body // "")
')"

[ -n "$marker" ] || not_ready "missing-trusted-verification-marker"

marker_date="$(printf '%s' "$marker" | sed -nE \
  's/.*agent-prep:verified[[:space:]]+date=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
marker_sha="$(printf '%s' "$marker" | sed -nE \
  's/.*body-sha=([0-9a-f]{12}).*/\1/p')"

[ -n "$marker_date" ] && [ -n "$marker_sha" ] \
  || not_ready "malformed-verification-marker"

days_since="$(python3 - "$as_of" "$marker_date" <<'PY'
from datetime import date
import sys
try:
    as_of = date.fromisoformat(sys.argv[1])
    marker = date.fromisoformat(sys.argv[2])
except ValueError:
    sys.exit(2)
print((as_of - marker).days)
PY
)" || not_ready "malformed-verification-marker"

[ "$marker_sha" = "$current_sha" ] || not_ready "body-sha-mismatch"
[ "$days_since" -ge 0 ] || not_ready "malformed-verification-marker"
[ "$days_since" -le 7 ] || not_ready "agent-ready-stale"

printf 'status=ready\n'
printf 'issue=%s\n' "$number"
printf 'verified-date=%s\n' "$marker_date"
printf 'body-sha=%s\n' "$current_sha"
