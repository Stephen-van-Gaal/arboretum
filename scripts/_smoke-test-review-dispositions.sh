#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-review-dispositions.sh"
SKILL="$SCRIPT_DIR/../skills/review-evaluate/SKILL.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
note() { echo "FAIL: $1"; fail=1; }

mkdir -p "$tmp/.arboretum/land/580"
cat > "$tmp/.arboretum/land/580/comments.json" <<'JSON'
[
  {
    "id": 111,
    "surface": "inline",
    "status": "open",
    "reply_handle": {
      "comment_id": 111,
      "thread_id": "THREAD111"
    }
  }
]
JSON

write_dispositions() {
  cat > "$tmp/.arboretum/land/580/dispositions.json"
}

write_dispositions <<'JSON'
{
  "schema": "review-dispositions.v1",
  "pr": 580,
  "items": [
    {
      "comment_id": 111,
      "disposition": "fix",
      "severity": "substantive",
      "action": "fix-in-batch",
      "cluster": "cluster-a",
      "resolve_after_closeout": true,
      "reply": "Fixed in the next push.",
      "reason": "Correctness issue."
    }
  ]
}
JSON
(cd "$tmp" && bash "$VALIDATE" 580) >/dev/null 2>&1 || note "valid dispositions should pass"

write_dispositions <<'JSON'
{
  "schema": "review-dispositions.v1",
  "pr": 580,
  "items": [
    {
      "comment_id": 999,
      "disposition": "fix",
      "severity": "substantive",
      "action": "fix-in-batch",
      "cluster": "cluster-a",
      "resolve_after_closeout": true,
      "reply": "Fixed.",
      "reason": "Unknown id."
    }
  ]
}
JSON
(cd "$tmp" && bash "$VALIDATE" 580) >/dev/null 2>&1 && note "unknown comment id should fail"

write_dispositions <<'JSON'
{
  "schema": "review-dispositions.v1",
  "pr": 580,
  "items": [
    {
      "comment_id": 111,
      "disposition": "invented",
      "severity": "substantive",
      "action": "fix-in-batch",
      "cluster": "cluster-a",
      "resolve_after_closeout": true,
      "reply": "Fixed.",
      "reason": "Bad enum."
    }
  ]
}
JSON
(cd "$tmp" && bash "$VALIDATE" 580) >/dev/null 2>&1 && note "unknown disposition enum should fail"

write_dispositions <<'JSON'
{
  "schema": "review-dispositions.v1",
  "pr": 580,
  "items": [
    {
      "comment_id": 111,
      "disposition": "fix",
      "severity": "substantive",
      "action": "fix-in-batch",
      "resolve_after_closeout": true,
      "reply": "Fixed.",
      "reason": "Missing cluster."
    }
  ]
}
JSON
(cd "$tmp" && bash "$VALIDATE" 580) >/dev/null 2>&1 && note "fix without cluster should fail"

write_dispositions <<'JSON'
{
  "schema": "review-dispositions.v1",
  "pr": 580,
  "items": [
    {
      "comment_id": 111,
      "disposition": "already-addressed",
      "severity": "substantive",
      "action": "no-code-change",
      "resolve_after_closeout": true,
      "reply": "",
      "reason": "No reply."
    }
  ]
}
JSON
(cd "$tmp" && bash "$VALIDATE" 580) >/dev/null 2>&1 && note "resolve_after_closeout without reply should fail"

if [ -f "$SKILL" ]; then
  grep -q "do not post comments" "$SKILL" || note "review-evaluate skill should forbid posting comments"
  grep -q "do not .*resolve" "$SKILL" || note "review-evaluate skill should forbid resolving threads"
fi

[ "$fail" -eq 0 ] && echo "PASS: review-dispositions" || exit 1
