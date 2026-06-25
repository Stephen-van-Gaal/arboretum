#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# cleanup-tracker-closure.sh — Non-interactive helper for /cleanup tracker close.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "cleanup-tracker-closure.sh requires bash" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/roadmap/lib.sh
source "$PROJECT_DIR/scripts/roadmap/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  cleanup-tracker-closure.sh classify --pr <pr-number> --issue <issue> [--issue <issue>...]
  cleanup-tracker-closure.sh close --pr <pr-number> --issue <issue> --confirm-close
EOF
  exit 2
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
value = data.get(sys.argv[2], "")
print("" if value is None else value)
PY
}

classify_one() {
  local pr="$1"
  local issue="$2"
  local closure issue_json

  if ! closure="$(roadmap_tracker_pr_closure_status "$pr" "$issue")"; then
    echo "cleanup-tracker-closure: failed to read closure status for PR $pr / issue $issue" >&2
    return 2
  fi

  if ! issue_json="$(roadmap_tracker_issue_show "$issue" --json number,title,state,url)"; then
    echo "cleanup-tracker-closure: failed to read tracker issue $issue" >&2
    return 2
  fi

  python3 - "$pr" "$issue" "$closure" "$issue_json" <<'PY'
import json
import sys

pr, requested_issue, closure_text, issue_text = sys.argv[1:5]
closure = {}
for line in closure_text.splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        closure[key] = value

try:
    issue = json.loads(issue_text)
except json.JSONDecodeError as exc:
    sys.stderr.write(f"cleanup-tracker-closure: malformed issue JSON: {exc}\n")
    sys.exit(2)

provider = closure.get("provider", "unknown")
intent = closure.get("intent", "unknown")
verification = closure.get("verification", "unknown")
evidence = closure.get("evidence", "")
number = str(issue.get("number") or requested_issue)
title = str(issue.get("title") or "")
state = str(issue.get("state") or "")
url = str(issue.get("url") or "")

open_states = {"open", "active", "new"}
state_open = state.lower() in open_states

status = "unknown"
reason = "closure status is unknown"
if verification == "unsupported":
    status = "unsupported"
    reason = evidence or "provider does not support closure verification"
elif verification == "unknown" or intent == "unknown":
    status = "unknown"
    reason = evidence or "closure verification is unknown"
elif state and not state_open:
    status = "already-closed"
    reason = f"tracker item state is {state}"
elif not state:
    status = "unknown"
    reason = "tracker item state is unavailable"
elif intent == "close" and verification == "supported":
    status = "closeable"
    reason = evidence or "merged PR declares close intent"
elif intent in {"reference", "none"}:
    status = "ambiguous"
    reason = evidence or "merged PR does not declare close intent"

print(json.dumps({
    "status": status,
    "provider": provider,
    "intent": intent,
    "verification": verification,
    "issue_number": number,
    "issue_title": title,
    "issue_state": state,
    "issue_url": url,
    "pr_number": str(pr),
    "evidence": evidence,
    "reason": reason,
}, separators=(",", ":")))
PY
}

emit_classifications() {
  local pr="$1"
  shift
  local objects_file
  objects_file="$(mktemp)"
  trap 'rm -f "$objects_file"' RETURN

  local issue
  for issue in "$@"; do
    classify_one "$pr" "$issue" >> "$objects_file"
  done

  python3 - "$objects_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = [json.loads(line) for line in f if line.strip()]
print(json.dumps(data, separators=(",", ":")))
PY
}

subcommand="${1:-}"
[ -n "$subcommand" ] || usage
shift

case "$subcommand" in
  classify|close) ;;
  *) usage ;;
esac

pr=""
confirm_close=0
issues=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || usage
      pr="$2"
      shift 2
      ;;
    --issue)
      [ "$#" -ge 2 ] || usage
      issues+=("$2")
      shift 2
      ;;
    --confirm-close)
      confirm_close=1
      shift
      ;;
    *)
      echo "cleanup-tracker-closure: unsupported argument: $1" >&2
      usage
      ;;
  esac
done

[ -n "$pr" ] || usage
[ "${#issues[@]}" -gt 0 ] || usage

case "$subcommand" in
  classify)
    emit_classifications "$pr" "${issues[@]}"
    ;;
  close)
    if [ "${#issues[@]}" -ne 1 ]; then
      echo "cleanup-tracker-closure: close requires exactly one --issue" >&2
      exit 1
    fi
    if [ "$confirm_close" -ne 1 ]; then
      echo "cleanup-tracker-closure: close requires --confirm-close" >&2
      exit 1
    fi

    classification="$(classify_one "$pr" "${issues[0]}")"
    status="$(json_field "$classification" status)"
    if [ "$status" != "closeable" ]; then
      printf '%s\n' "$classification"
      exit 1
    fi

    evidence="$(json_field "$classification" evidence)"
    roadmap_tracker_issue_close "${issues[0]}" \
      --reason completed \
      --comment "Closed by Arboretum cleanup after verifying merged PR #$pr completed this work.
Evidence: $evidence"
    printf '%s\n' "$classification"
    ;;
esac
