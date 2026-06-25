#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# Smoke test: collect-review.sh — comprehensive multi-surface normalization,
# 3-state status, control-char scrub, priority harvest, ledger write,
# --unanswered. Uses COLLECT_FIXTURE_DIR so it never touches the network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT="$SCRIPT_DIR/collect-review.sh"
fail=0
note() { echo "FAIL: $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/proj" "$tmp/fix"

# ---------- GitHub fixtures (controlled; embeds a control char for scrub) ----------
cat > "$tmp/proj/.arboretum.yml" <<'YML'
backend: github
YML
python3 - "$tmp/fix" <<'PY'
import json, os, sys
d = sys.argv[1]
inline = [
  {"id": 111, "path": "a.md", "line": 5, "user": {"login": "chatgpt-codex-connector"},
   "in_reply_to_id": None,
   "body": "![P1](https://img.shields.io/badge/P1-red) real bug [31mRED[0m"},
  {"id": 222, "path": "b.md", "line": 9, "user": {"login": "Copilot"},
   "in_reply_to_id": None, "body": "nit: rename this"},
  {"id": 333, "path": "b.md", "line": 9, "user": {"login": "stvangaal"},
   "in_reply_to_id": 222, "body": "Fixed in abc1234."},
  # Open (unresolved) thread where we already replied — our reply (445) must not
  # surface as unanswered, and the root (444) is answered by it.
  {"id": 444, "path": "c.md", "line": 3, "user": {"login": "Copilot"},
   "in_reply_to_id": None, "body": "consider X"},
  {"id": 445, "path": "c.md", "line": 3, "user": {"login": "stvangaal"},
   "in_reply_to_id": 444, "body": "Done in def5678."},
]
reviews = [
  {"id": 900, "user": {"login": "Copilot"}, "state": "COMMENTED", "body": "Summary: overall ok"},
  {"id": 901, "user": {"login": "stvangaal"}, "state": "COMMENTED", "body": ""},
]
conv = [{"id": 700, "user": {"login": "chatgpt-codex-connector"},
         "body": "Didn't find any major issues"}]
threads = {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
  {"id": "THREAD111", "isResolved": False, "isOutdated": False, "comments": {"nodes": [
    {"databaseId": 111, "author": {"login": "chatgpt-codex-connector"}, "body": "x"}]}},
  {"id": "THREAD222", "isResolved": True, "isOutdated": False, "comments": {"nodes": [
    {"databaseId": 222, "author": {"login": "Copilot"}, "body": "y"},
    {"databaseId": 333, "author": {"login": "stvangaal"}, "body": "Fixed"}]}},
  {"id": "THREAD444", "isResolved": False, "isOutdated": True, "comments": {"nodes": [
    {"databaseId": 444, "author": {"login": "Copilot"}, "body": "consider X"},
    {"databaseId": 445, "author": {"login": "stvangaal"}, "body": "Done"}]}},
]}}}}}
for name, obj in [("gh-inline", inline), ("gh-reviews", reviews),
                  ("gh-conversation", conv), ("gh-threads", threads)]:
    with open(os.path.join(d, name + ".json"), "w") as f:
        json.dump(obj, f)
PY

out="$(cd "$tmp/proj" && COLLECT_FIXTURE_DIR="$tmp/fix" bash "$COLLECT" 555 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "collect should exit 0 (got $rc): $out"

# Surface coverage — each non-empty surface represented.
for s in review-summary inline conversation; do
  echo "$out" | jq -e --arg s "$s" 'any(.[]; .surface==$s)' >/dev/null 2>&1 || note "surface $s missing"
done
# 3-state status enum.
echo "$out" | jq -e 'all(.[]; .status=="open" or .status=="resolved" or .status=="none")' >/dev/null 2>&1 || note "status not in 3-state enum"
# Control-char scrub — no  survives in any body.
echo "$out" | grep -qi 'u001b' && note "control char not scrubbed"
# Priority harvested from the Codex P1 badge.
echo "$out" | jq -e 'any(.[]; .priority=="P1")' >/dev/null 2>&1 || note "P1 priority not parsed"
# Thread resolved-state mapped.
echo "$out" | jq -e 'any(.[]; .id==111 and .status=="open")' >/dev/null 2>&1 || note "id 111 should be open"
echo "$out" | jq -e 'any(.[]; .id==222 and .status=="resolved")' >/dev/null 2>&1 || note "id 222 should be resolved"
# reply_handle is surface-dependent: inline carries an in_reply_to target; review
# summaries and conversation comments are not in_reply_to targets → null.
echo "$out" | jq -e 'any(.[]; .surface=="inline" and .id==111 and .reply_handle.comment_id==111)' >/dev/null 2>&1 || note "inline reply_handle should carry comment_id"
echo "$out" | jq -e 'any(.[]; .id==111 and .reply_handle.thread_id=="THREAD111" and .is_outdated==false)' >/dev/null 2>&1 || note "github inline should include thread_id and is_outdated=false"
echo "$out" | jq -e 'any(.[]; .id==444 and .reply_handle.thread_id=="THREAD444" and .is_outdated==true)' >/dev/null 2>&1 || note "github inline should include outdated state"
echo "$out" | jq -e 'any(.[]; .surface=="review-summary" and .reply_handle==null)' >/dev/null 2>&1 || note "review-summary reply_handle should be null"
echo "$out" | jq -e 'any(.[]; .surface=="conversation" and .reply_handle==null)' >/dev/null 2>&1 || note "conversation reply_handle should be null"
# Approval channel + comments ledger written.
[ -f "$tmp/proj/.arboretum/land/555/comments.json" ] || note "comments.json ledger not written"
[ -f "$tmp/proj/.arboretum/land/555/approvals.json" ] || note "approvals.json not written"
jq -e 'any(.[]; .reviewer=="Copilot" and .state=="COMMENTED")' "$tmp/proj/.arboretum/land/555/approvals.json" >/dev/null 2>&1 || note "approval channel missing Copilot state"

# --unanswered: 111 open + no reply → present; 222 resolved → absent.
un="$(cd "$tmp/proj" && COLLECT_FIXTURE_DIR="$tmp/fix" bash "$COLLECT" 555 --unanswered 2>&1)"
echo "$un" | jq -e 'any(.[]; .id==111)' >/dev/null 2>&1 || note "--unanswered should include open unreplied 111"
echo "$un" | jq -e 'any(.[]; .id==222)' >/dev/null 2>&1 && note "--unanswered should exclude resolved 222"
# Our own reply (445) in an open thread is a disposition, not hanging feedback.
echo "$un" | jq -e 'any(.[]; .id==445)' >/dev/null 2>&1 && note "--unanswered should exclude our own reply 445"
# Root 444 is answered by our reply → excluded.
echo "$un" | jq -e 'any(.[]; .id==444)' >/dev/null 2>&1 && note "--unanswered should exclude answered root 444"

# ---------- Azure DevOps fixtures (real human-review collection) ----------
mkdir -p "$tmp/ado-proj" "$tmp/ado-fix"
cat > "$tmp/ado-proj/.arboretum.yml" <<'YML'
backend: azure-devops
YML
cat > "$tmp/ado-fix/ado-threads.json" <<'JSON'
{ "value": [
  { "id": 1, "status": "active",
    "threadContext": {"filePath":"/src/a.ts","rightFileStart":{"line":10}},
    "comments": [ {"id":1,"parentCommentId":0,"author":{"displayName":"Alice"},"content":"please fix this","commentType":"text"} ] },
  { "id": 2, "status": "fixed", "threadContext": null,
    "comments": [ {"id":1,"author":{"displayName":"Bob"},"content":"resolved now","commentType":"text"},
                  {"id":2,"parentCommentId":1,"author":{"displayName":"Alice"},"content":"thanks","commentType":"text"} ] },
  { "id": 3, "status": "active",
    "comments": [ {"id":1,"author":{"displayName":"Azure DevOps"},"content":"Alice voted 10","commentType":"system"} ] }
] }
JSON
aout="$(cd "$tmp/ado-proj" && COLLECT_FIXTURE_DIR="$tmp/ado-fix" bash "$COLLECT" 42 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "ado collect should exit 0 (got $rc): $aout"
# System thread filtered → exactly two records, both ado-thread.
[ "$(echo "$aout" | jq 'length')" = "2" ] || note "ado: expected 2 records (system filtered), got $(echo "$aout" | jq 'length')"
echo "$aout" | jq -e 'all(.[]; .surface=="ado-thread" and .backend=="azure-devops")' >/dev/null 2>&1 || note "ado: surface/backend wrong"
# 7→3 status map: active→open, fixed→resolved.
echo "$aout" | jq -e 'any(.[]; .id==1 and .status=="open")' >/dev/null 2>&1 || note "ado: active should map to open"
echo "$aout" | jq -e 'any(.[]; .id==2 and .status=="resolved")' >/dev/null 2>&1 || note "ado: fixed should map to resolved"
# threadContext → file/line.
echo "$aout" | jq -e 'any(.[]; .id==1 and .file=="/src/a.ts" and .line==10)' >/dev/null 2>&1 || note "ado: threadContext not projected"
# Compound reply_handle.
echo "$aout" | jq -e 'any(.[]; .id==1 and .reply_handle.thread_id==1 and .reply_handle.parent_comment_id==1)' >/dev/null 2>&1 || note "ado: reply_handle missing thread/parent ids"
# System thread (id 3) excluded.
echo "$aout" | jq -e 'any(.[]; .id==3)' >/dev/null 2>&1 && note "ado: system thread should be filtered out"
# --unanswered: open single-comment thread 1 present; resolved+replied thread 2 absent.
aun="$(cd "$tmp/ado-proj" && COLLECT_FIXTURE_DIR="$tmp/ado-fix" bash "$COLLECT" 42 --unanswered 2>&1)"
echo "$aun" | jq -e 'any(.[]; .id==1)' >/dev/null 2>&1 || note "ado --unanswered should include open thread 1"
echo "$aun" | jq -e 'any(.[]; .id==2)' >/dev/null 2>&1 && note "ado --unanswered should exclude resolved thread 2"

[ "$fail" -eq 0 ] && echo "PASS: collect-review (github + ado)" || exit 1
