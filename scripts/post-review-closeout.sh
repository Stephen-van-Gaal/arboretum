#!/usr/bin/env bash
# owner: git-workflow-tooling
# post-review-closeout.sh <pr> [--dry-run]
#
# Validate review closeout ledgers, verify local/provider head safety, post
# thread replies, resolve addressed GitHub review threads, post a summary, and
# write closeout evidence.
set -uo pipefail

PR=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "post-review-closeout.sh: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$PR" ] && PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || { echo "usage: post-review-closeout.sh <pr> [--dry-run]" >&2; exit 2; }
case "$PR" in *[!0-9]*) echo "post-review-closeout.sh: PR must be a positive integer (got '$PR')" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
LAND_DIR="$ROOT/.arboretum/land/$PR"
COMMENTS="$LAND_DIR/comments.json"
DISPOSITIONS="$LAND_DIR/dispositions.json"
FIXES="$LAND_DIR/fixes.json"
CLOSEOUT="$LAND_DIR/closeout.json"
VALIDATE="$SCRIPT_DIR/validate-review-dispositions.sh"

[ -f "$COMMENTS" ] || { echo "post-review-closeout.sh: missing $COMMENTS" >&2; exit 2; }
[ -f "$DISPOSITIONS" ] || { echo "post-review-closeout.sh: missing $DISPOSITIONS" >&2; exit 2; }
[ -f "$FIXES" ] || { echo "post-review-closeout.sh: missing $FIXES" >&2; exit 2; }

bash "$VALIDATE" "$PR" >/dev/null || exit $?
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || {
  echo "post-review-closeout.sh: cannot read local HEAD" >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLAN="$WORK/plan.json"
SUMMARY="$WORK/summary.md"
COMMITS="$WORK/commits.txt"

python3 - "$PR" "$HEAD_SHA" "$COMMENTS" "$DISPOSITIONS" "$FIXES" "$PLAN" "$SUMMARY" "$COMMITS" <<'PY'
import json
import sys

pr_raw, head_sha, comments_path, dispositions_path, fixes_path, plan_path, summary_path, commits_path = sys.argv[1:9]
pr = int(pr_raw)


def load(path, exit_code=2):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        print(f"post-review-closeout.sh: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(exit_code)


def fail(message, code=1):
    print(f"CLOSEOUT-DRIFT: {message}", file=sys.stderr)
    sys.exit(code)


comments = load(comments_path)
dispositions = load(dispositions_path)
fixes = load(fixes_path)

if not isinstance(comments, list):
    fail("comments.json must be an array")
if not isinstance(dispositions, dict):
    fail("dispositions.json must be an object")
if not isinstance(fixes, dict):
    fail("fixes.json must be an object")
if fixes.get("schema") != "review-fixes.v1":
    fail("fixes.json schema must be review-fixes.v1")
if fixes.get("pr") != pr:
    fail(f"fixes.json pr must be {pr}")
fix_head = fixes.get("head_sha")
if fix_head and fix_head != head_sha:
    fail(f"fixes.json head_sha {fix_head} does not match local HEAD {head_sha}")

comment_by_id = {
    item.get("id"): item for item in comments
    if isinstance(item, dict) and item.get("id") is not None
}

fix_commits_by_comment = {}
fix_items = fixes.get("items")
if not isinstance(fix_items, list):
    fail("fixes.json items must be an array")
for index, item in enumerate(fix_items):
    if not isinstance(item, dict):
        fail(f"fixes.items[{index}] must be an object")
    cid = item.get("comment_id")
    commits = item.get("commits", item.get("fix_commits", []))
    if isinstance(commits, str):
        commits = [commits]
    if not isinstance(commits, list) or not all(isinstance(sha, str) and sha.strip() for sha in commits):
        fail(f"fixes.items[{index}].commits must be a non-empty string array")
    fix_commits_by_comment.setdefault(cid, []).extend(commits)

actions = []
remaining_open = []
summary_fixed = []
summary_remaining = []
all_cited_commits = []

items = dispositions.get("items") or []
for item in items:
    cid = item.get("comment_id")
    comment = comment_by_id.get(cid)
    if comment is None:
        fail(f"disposition references unknown comment_id {cid}")
    reply_handle = comment.get("reply_handle") or {}
    disposition = item.get("disposition")
    severity = item.get("severity")
    reason = item.get("reason") or ""
    reply = item.get("reply") or ""
    should_resolve = item.get("resolve_after_closeout") is True
    commits = fix_commits_by_comment.get(cid, [])

    if disposition == "fix" and not commits:
        fail(f"fix disposition for comment {cid} has no cited fix commits")
    all_cited_commits.extend(commits)

    if should_resolve:
        if comment.get("backend") != "github":
            fail(f"closeout mutation is only supported for github comment {cid}")
        comment_id = reply_handle.get("comment_id")
        thread_id = reply_handle.get("thread_id")
        if not comment_id:
            fail(f"comment {cid} is missing reply_handle.comment_id")
        if not thread_id:
            fail(f"comment {cid} is missing reply_handle.thread_id")
        actions.append({
            "type": "reply",
            "comment_id": comment_id,
            "body": reply,
            "source_comment_id": cid,
        })
        actions.append({
            "type": "resolve",
            "thread_id": thread_id,
            "source_comment_id": cid,
        })
        summary_fixed.append(f"- #{cid}: {disposition} - {reason}")
    elif severity == "substantive":
        remaining = {
            "comment_id": cid,
            "disposition": disposition,
            "action": item.get("action"),
            "reason": reason,
        }
        remaining_open.append(remaining)
        summary_remaining.append(f"- #{cid}: {disposition} - {reason}")

actions.append({"type": "summary", "body_file": summary_path})

summary_lines = [
    f"Review closeout for PR #{pr}",
    "",
    f"Head: `{head_sha}`",
    "",
    "Addressed:",
]
summary_lines.extend(summary_fixed or ["- None"])
summary_lines.extend(["", "Remaining open:"])
summary_lines.extend(summary_remaining or ["- None"])
summary_lines.append("")

with open(summary_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(summary_lines))

with open(commits_path, "w", encoding="utf-8") as handle:
    for sha in sorted(set(all_cited_commits)):
        handle.write(f"{sha}\n")

with open(plan_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "review-closeout-plan.v1",
        "pr": pr,
        "head_sha": head_sha,
        "actions": actions,
        "remaining_open": remaining_open,
    }, handle, indent=2)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] || exit "$py_rc"

while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  if ! git -C "$ROOT" merge-base --is-ancestor "$sha" HEAD >/dev/null 2>&1; then
    echo "post-review-closeout.sh: cited fix commit $sha is not reachable from local HEAD $HEAD_SHA" >&2
    exit 1
  fi
done < "$COMMITS"

PR_JSON="$(gh pr view "$PR" --json state,headRefOid 2>/dev/null)" || {
  echo "post-review-closeout.sh: failed to read PR #$PR state" >&2
  exit 1
}
python3 - "$PR" "$HEAD_SHA" "$PR_JSON" <<'PY'
import json
import sys

pr, head, raw = sys.argv[1:4]
try:
    data = json.loads(raw)
except Exception as exc:
    print(f"post-review-closeout.sh: invalid gh pr view JSON: {exc}", file=sys.stderr)
    sys.exit(1)
if data.get("state") != "OPEN":
    print(f"post-review-closeout.sh: PR #{pr} is not open (state={data.get('state')})", file=sys.stderr)
    sys.exit(1)
provider_head = data.get("headRefOid")
if provider_head and provider_head != head:
    print(
        f"post-review-closeout.sh: provider head {provider_head} does not match local HEAD {head}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
state_rc=$?
[ "$state_rc" -eq 0 ] || exit "$state_rc"

if [ "$DRY_RUN" -eq 1 ]; then
  python3 - "$PLAN" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    plan = json.load(handle)
for action in plan["actions"]:
    if action["type"] == "reply":
        print(f"DRY-RUN: reply comment_id={action['comment_id']}")
    elif action["type"] == "resolve":
        print(f"DRY-RUN: resolve thread_id={action['thread_id']}")
    elif action["type"] == "summary":
        print("DRY-RUN: summary comment")
print(f"DRY-RUN: remaining_open={len(plan['remaining_open'])}")
PY
  exit 0
fi

python3 - "$PR" "$PLAN" "$SUMMARY" <<'PY'
import json
import subprocess
import sys

pr, plan_path, summary_path = sys.argv[1:4]
with open(plan_path, encoding="utf-8") as handle:
    plan = json.load(handle)

for action in plan["actions"]:
    try:
        if action["type"] == "reply":
            subprocess.run(
                [
                    "gh",
                    "api",
                    f"repos/{{owner}}/{{repo}}/pulls/{pr}/comments/{action['comment_id']}/replies",
                    "-f",
                    f"body={action['body']}",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        elif action["type"] == "resolve":
            subprocess.run(
                [
                    "gh",
                    "api",
                    "graphql",
                    "-f",
                    f"threadId={action['thread_id']}",
                    "-f",
                    "query=mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        elif action["type"] == "summary":
            subprocess.run(
                ["gh", "pr", "comment", pr, "--body-file", summary_path],
                check=True,
                stdout=subprocess.DEVNULL,
            )
    except subprocess.CalledProcessError as exc:
        print(f"post-review-closeout.sh: provider write failed during {action['type']}: {exc}", file=sys.stderr)
        sys.exit(3)
PY
write_rc=$?
[ "$write_rc" -eq 0 ] || exit "$write_rc"

python3 - "$PLAN" "$CLOSEOUT" <<'PY'
import json
import sys

plan_path, closeout_path = sys.argv[1:3]
with open(plan_path, encoding="utf-8") as handle:
    plan = json.load(handle)
with open(closeout_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "review-closeout.v1",
        "pr": plan["pr"],
        "head_sha": plan["head_sha"],
        "actions": plan["actions"],
        "remaining_open": plan["remaining_open"],
    }, handle, indent=2)
    handle.write("\n")
PY

echo "PASS: review closeout posted for PR #$PR"
