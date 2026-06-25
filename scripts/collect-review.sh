#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# collect-review.sh <pr> [--unanswered]
#
# Aggregate every PR comment surface into one backend-neutral normalized
# record list + a separate approval/vote channel, write them to the per-PR
# run-state ledger (.arboretum/land/<pr>/comments.json + approvals.json), and
# echo the comment array to stdout.
#
# Normalized record:
#   { surface, backend, id, file, line, author, body, status, reply_handle, priority, is_outdated? }
#   status ∈ open | resolved | none   (3-state, per-backend mapping)
#   priority ∈ P1|P2|P3|null          (harvested from a reviewer self-label)
#
# Surfaces (github): pulls/{N}/reviews (summaries) + pulls/{N}/comments
#   (inline) + issues/{N}/comments (conversation) + GraphQL reviewThreads.
# Surfaces (azure-devops): pullRequests/{id}/threads — human comment threads;
#   commentType:system threads (votes/pushes/merges) are filtered out.
#
# --unanswered: print only open-status records with no reply.
# COLLECT_FIXTURE_DIR: read fixtures from that dir instead of the network
#   (github: gh-*.json; azure-devops: ado-threads.json). Offline tests.
# Bodies are control-char scrubbed at source.
set -uo pipefail

PR=""; UNANSWERED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unanswered) UNANSWERED=1; shift ;;
    -*) echo "collect-review.sh: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$PR" ] && PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || { echo "usage: collect-review.sh <pr> [--unanswered]" >&2; exit 2; }
case "$PR" in *[!0-9]*) echo "collect-review.sh: PR must be a positive integer (got '$PR')" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/roadmap/lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/scrub-control-chars.sh"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
BACKEND="$(roadmap_backend "$ROOT")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Defaults; each backend branch overrides the inputs it uses.
INLINE=/dev/null; REVIEWS=/dev/null; CONV=/dev/null; THREADS=/dev/null

case "$BACKEND" in
  github)
    if [ -n "${COLLECT_FIXTURE_DIR:-}" ]; then
      SRC="$COLLECT_FIXTURE_DIR"
    else
      # Resolve owner/name once — gh graphql does not expand {owner}/{repo}.
      OR="$(gh repo view --json owner,name --jq '.owner.login+" "+.name' 2>/dev/null)"
      OWNER="${OR% *}"; NAME="${OR#* }"
      OWNER_REPO="repos/$OWNER/$NAME"
      # PR-vs-issue guard (live only).
      if ! gh api "$OWNER_REPO/pulls/$PR" --jq .number >/dev/null 2>&1; then
        echo "collect-review.sh: #$PR is not a pull request (or is unreachable)." >&2; exit 2
      fi
      # Fail loudly on a genuine fetch error. Substituting '[]' would write a
      # "successful" partial ledger and let --unanswered pass while real feedback
      # silently disappears. An empty surface returns [] with exit 0; only a real
      # failure (rate limit, transient error, missing permission) is non-zero.
      for spec in "pulls/$PR/comments:gh-inline" "pulls/$PR/reviews:gh-reviews" "issues/$PR/comments:gh-conversation"; do
        ep="${spec%%:*}"; out="${spec##*:}"
        gh api "$OWNER_REPO/$ep" --paginate > "$WORK/$out.json" 2>/dev/null || {
          echo "collect-review.sh: failed to fetch '$ep' for PR $PR — refusing to write a partial ledger." >&2; exit 3; }
      done
      # shellcheck disable=SC2016  # $number/$owner/$name are GraphQL variables, not shell.
      gh api graphql -F number="$PR" -F owner="$OWNER" -F name="$NAME" -f query='
        query($number:Int!,$owner:String!,$name:String!){repository(owner:$owner,name:$name){
          pullRequest(number:$number){reviewThreads(first:100){nodes{
            id isResolved isOutdated comments(first:50){nodes{databaseId author{login} body}}}}}}}' \
        > "$WORK/gh-threads.json" 2>/dev/null || {
          echo "collect-review.sh: failed to fetch review-thread state for PR $PR — refusing to write a partial ledger." >&2; exit 3; }
      SRC="$WORK"
    fi
    INLINE="$SRC/gh-inline.json"; REVIEWS="$SRC/gh-reviews.json"
    CONV="$SRC/gh-conversation.json"; THREADS="$SRC/gh-threads.json"
    ;;
  azure-devops)
    if [ -n "${COLLECT_FIXTURE_DIR:-}" ]; then
      THREADS="$COLLECT_FIXTURE_DIR/ado-threads.json"
    else
      # Live Azure Repos PR threads via the REST surface. Untested in this repo
      # (github backend); the normalization below is fixture-covered.
      PR_JSON="$(az repos pr show --id "$PR" -o json 2>/dev/null)" || {
        echo "collect-review.sh: Azure Repos PR $PR not found/unreachable." >&2; exit 2; }
      REPO_ID="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("repository") or {}).get("id",""))' 2>/dev/null)"
      PROJ="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("repository") or {}).get("project") or {}).get("name",""))' 2>/dev/null)"
      az devops invoke --area git --resource pullRequestThreads \
        --route-parameters project="$PROJ" repositoryId="$REPO_ID" pullRequestId="$PR" \
        --api-version 7.1 -o json > "$WORK/ado-threads.json" 2>/dev/null \
        || echo '{"value":[]}' > "$WORK/ado-threads.json"
      THREADS="$WORK/ado-threads.json"
    fi
    ;;
  *)
    echo "collect-review.sh: unsupported backend: $BACKEND" >&2
    exit 2
    ;;
esac

OUTDIR="$ROOT/.arboretum/land/$PR"
mkdir -p "$OUTDIR"

python3 - "$INLINE" "$REVIEWS" "$CONV" "$THREADS" "$BACKEND" "$OUTDIR" "$UNANSWERED" <<'PY'
import json, os, re, sys

inline_p, reviews_p, conv_p, threads_p, backend, outdir, unanswered = sys.argv[1:8]

_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def priority(body):
    if not body:
        return None
    m = re.search(r"badge/P([123])", body) or re.search(r"\bP([123])\b", body[:60])
    return f"P{m.group(1)}" if m else None

records, approvals = [], []
answered = set()
reply_ids = set()  # ids of our own inline replies — never themselves "unanswered"

if backend == "github":
    threads = load(threads_p)
    try:
        tnodes = threads["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    except Exception:
        tnodes = []
    # The reviewThreads query is capped at first:100 (no cursor pagination yet).
    # Warn loudly rather than silently classify beyond-cap threads as open — full
    # GraphQL pagination is a follow-up. Never silently truncate.
    if len(tnodes) >= 100:
        sys.stderr.write(
            "collect-review.sh: WARNING — review threads capped at 100; threads "
            "beyond the first page are unclassified and may show as open. Full "
            "pagination is a follow-up.\n")
    resolved_ids, open_ids = set(), set()
    thread_by_comment = {}
    outdated_by_comment = {}
    for t in tnodes:
        target = resolved_ids if t.get("isResolved") else open_ids
        thread_id = t.get("id")
        is_outdated = bool(t.get("isOutdated"))
        for c in (t.get("comments", {}).get("nodes") or []):
            cid = c.get("databaseId")
            if cid is not None:
                target.add(cid)
                if thread_id:
                    thread_by_comment[cid] = thread_id
                outdated_by_comment[cid] = is_outdated

    inline = load(inline_p)
    for c in inline:
        cid = c.get("id")
        status = "resolved" if cid in resolved_ids else "open"
        body = c.get("body") or ""
        reply_handle = {"comment_id": cid}
        thread_id = thread_by_comment.get(cid)
        if thread_id:
            reply_handle["thread_id"] = thread_id
        records.append({
            "surface": "inline", "backend": "github", "id": cid,
            "file": c.get("path"), "line": c.get("line"),
            "author": (c.get("user") or {}).get("login"),
            "body": scrub(body), "status": status,
            "reply_handle": reply_handle,
            "priority": priority(body),
            "is_outdated": outdated_by_comment.get(cid, False),
        })

    for r in load(reviews_p):
        login = (r.get("user") or {}).get("login")
        approvals.append({"backend": "github", "reviewer": login, "state": r.get("state")})
        body = r.get("body") or ""
        if body.strip():
            records.append({
                "surface": "review-summary", "backend": "github", "id": r.get("id"),
                "file": None, "line": None, "author": login,
                "body": scrub(body), "status": "none",
                # A PR-review id is not an in_reply_to target — there is no inline
                # comment to thread a reply onto for a review summary.
                "reply_handle": None,
                "priority": priority(body),
            })

    # Conversation (top-level issue) comments have no resolvable thread, so they
    # carry status "none" and stay out of the --unanswered gate. Whether a
    # substantive top-level finding should count toward that gate is finalized in
    # M-C (#535), where /land acts on the gate.
    for c in load(conv_p):
        body = c.get("body") or ""
        records.append({
            "surface": "conversation", "backend": "github", "id": c.get("id"),
            "file": None, "line": None, "author": (c.get("user") or {}).get("login"),
            "body": scrub(body), "status": "none",
            # An issues/{N}/comments id is not an in_reply_to target for inline
            # review comments; replying is a fresh conversation comment.
            "reply_handle": None,
            "priority": priority(body),
        })

    answered = {c.get("in_reply_to_id") for c in inline if c.get("in_reply_to_id")}
    # A reply is our disposition, not feedback awaiting one — exclude it from the gate.
    reply_ids = {c.get("id") for c in inline if c.get("in_reply_to_id")}

elif backend == "azure-devops":
    ado = load(threads_p)
    items = ado.get("value", []) if isinstance(ado, dict) else (ado or [])
    # ADO's seven thread statuses → the 3-state model.
    STATUS_MAP = {
        "fixed": "resolved", "wontfix": "resolved", "closed": "resolved",
        "bydesign": "resolved", "active": "open", "pending": "open",
    }
    for t in items:
        comments = t.get("comments") or []
        # Filter system threads (votes, pushes, merges) — keep human text.
        text_comments = [
            c for c in comments
            if (c.get("commentType") or "text") != "system" and not c.get("isDeleted")
        ]
        if not text_comments:
            continue
        tstatus = (t.get("status") or "").lower()
        status = STATUS_MAP.get(tstatus, "none")
        tc = t.get("threadContext") or {}
        file = tc.get("filePath")
        line = (tc.get("rightFileStart") or {}).get("line")
        root = text_comments[0]
        content = root.get("content") or ""
        records.append({
            "surface": "ado-thread", "backend": "azure-devops", "id": t.get("id"),
            "file": file, "line": line,
            "author": (root.get("author") or {}).get("displayName"),
            "body": scrub(content), "status": status,
            "reply_handle": {"thread_id": t.get("id"), "parent_comment_id": root.get("id")},
            "priority": priority(content),
        })
        if len(text_comments) > 1:
            answered.add(t.get("id"))

else:
    sys.stderr.write(f"collect-review.sh: normalizer got unsupported backend {backend}\n")
    sys.exit(2)

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "comments.json"), "w", encoding="utf-8") as f:
    json.dump(records, f, indent=2)
with open(os.path.join(outdir, "approvals.json"), "w", encoding="utf-8") as f:
    json.dump(approvals, f, indent=2)

if unanswered == "1":
    out = [r for r in records
           if r["status"] == "open" and r["id"] not in answered and r["id"] not in reply_ids]
else:
    out = records
json.dump(out, sys.stdout, indent=2)
print()
PY
