#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/post-review-closeout.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
note() { echo "FAIL: $1"; fail=1; }

mkdir -p "$tmp/proj/.arboretum/land/580" "$tmp/bin"
(
  cd "$tmp/proj" || exit 1
  git init -q
  git config user.email "arboretum@example.invalid"
  git config user.name "Arboretum Test"
  printf 'initial\n' > README.md
  git add README.md
  git commit -q -m initial
)
head_sha="$(cd "$tmp/proj" && git rev-parse HEAD)"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
log="${GH_LOG:?}"
case "$1 $2" in
  "pr view")
    printf '{"state":"OPEN","headRefOid":"%s"}\n' "${GH_STUB_HEAD:?}"
    ;;
  "api graphql")
    thread=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f)
          case "${2:-}" in
            threadId=*) thread="${2#threadId=}" ;;
          esac
          shift 2
          ;;
        *) shift ;;
      esac
    done
    printf 'resolve %s\n' "$thread" >> "$log"
    printf '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}\n'
    ;;
  "api repos/"*)
    endpoint="$2"
    comment="${endpoint##*/comments/}"
    comment="${comment%%/*}"
    printf 'reply %s\n' "$comment" >> "$log"
    printf '{"id":9001}\n'
    ;;
  "pr comment")
    printf 'summary %s\n' "$3" >> "$log"
    printf 'https://example.invalid/comment/1\n'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 9
    ;;
esac
SH
chmod +x "$tmp/bin/gh"

write_ledgers() {
  local sha="$1"
  local ledger_head="${2:-$head_sha}"
  cat > "$tmp/proj/.arboretum/land/580/comments.json" <<'JSON'
[
  {
    "id": 111,
    "backend": "github",
    "surface": "inline",
    "status": "open",
    "reply_handle": {
      "comment_id": 111,
      "thread_id": "THREAD111"
    }
  },
  {
    "id": 222,
    "backend": "github",
    "surface": "inline",
    "status": "open",
    "reply_handle": {
      "comment_id": 222,
      "thread_id": "THREAD222"
    }
  }
]
JSON
  cat > "$tmp/proj/.arboretum/land/580/dispositions.json" <<'JSON'
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
      "reply": "Fixed in the pushed closeout commit.",
      "reason": "The issue was reproducible and fixed."
    },
    {
      "comment_id": 222,
      "disposition": "judgment-call",
      "severity": "substantive",
      "action": "ask-human",
      "resolve_after_closeout": false,
      "reply": "",
      "reason": "Needs human product judgment."
    }
  ]
}
JSON
  python3 - "$tmp/proj/.arboretum/land/580/fixes.json" "$sha" "$ledger_head" <<'PY'
import json
import sys
path, sha, head = sys.argv[1:4]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "review-fixes.v1",
        "pr": 580,
        "head_sha": head,
        "items": [
            {"comment_id": 111, "commits": [sha]}
        ]
    }, handle, indent=2)
PY
}

write_ledgers "$head_sha"
dry_out="$(
  cd "$tmp/proj" &&
    PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" GH_STUB_HEAD="$head_sha" \
      bash "$HELPER" 580 --dry-run 2>&1
)"
dry_rc=$?
[ "$dry_rc" -eq 0 ] || note "dry-run should pass (got $dry_rc): $dry_out"
[ ! -f "$tmp/gh.log" ] || note "dry-run should not call gh"
printf '%s\n' "$dry_out" | grep -q "reply comment_id=111" || note "dry-run should plan a thread reply"
printf '%s\n' "$dry_out" | grep -q "resolve thread_id=THREAD111" || note "dry-run should plan a thread resolve"
printf '%s\n' "$dry_out" | grep -q "summary comment" || note "dry-run should plan a summary comment"

rm -f "$tmp/gh.log"
live_out="$(
  cd "$tmp/proj" &&
    PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" GH_STUB_HEAD="$head_sha" \
      bash "$HELPER" 580 2>&1
)"
live_rc=$?
[ "$live_rc" -eq 0 ] || note "live closeout should pass (got $live_rc): $live_out"
cat > "$tmp/expected.log" <<'LOG'
reply 111
resolve THREAD111
summary 580
LOG
cmp -s "$tmp/expected.log" "$tmp/gh.log" || note "provider write order should be reply, resolve, summary"
jq -e '.schema=="review-closeout.v1" and .pr==580 and (.remaining_open | length)==1' \
  "$tmp/proj/.arboretum/land/580/closeout.json" >/dev/null 2>&1 || note "closeout.json should record remaining open judgment call"

rm -f "$tmp/gh.log" "$tmp/proj/.arboretum/land/580/closeout.json"
write_ledgers "0000000000000000000000000000000000000000" "$head_sha"
bad_out="$(
  cd "$tmp/proj" &&
    PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" GH_STUB_HEAD="$head_sha" \
      bash "$HELPER" 580 2>&1
)"
bad_rc=$?
[ "$bad_rc" -ne 0 ] || note "unreachable fix SHA should fail: $bad_out"
[ ! -f "$tmp/gh.log" ] || note "unreachable fix SHA should fail before gh writes"

[ "$fail" -eq 0 ] && echo "PASS: review-closeout" || exit 1
