#!/usr/bin/env bash
# owner: session-handoff
# _smoke-test-handoff-v2.sh — Verify session-handoff v2 (issue #251).
# Cases map to §5 contracts of the v2 design spec.
# Usage: bash scripts/_smoke-test-handoff-v2.sh
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; printf '%s\n' "$2" >&2; }
  exit 1
}
ok()   { echo "PASS: $1"; }

# A git repo fixture on a feature branch.
new_repo() {
  local fix="$ROOT_TMP/$1"
  mkdir -p "$fix"
  git -C "$fix" init -q
  git -C "$fix" config user.email "fixture@example.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m "seed"
  git -C "$fix" checkout -q -b feat/demo
  echo "$fix"
}

# A gh stub: logs every call to $GH_STUB_LOG, succeeds for the calls
# v2 makes (auth status, issue comment, issue view).
install_gh_stub() {
  local bindir="$1/.bin"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${GH_STUB_LOG:-/dev/null}"
case "$1 $2" in
  "auth status")  exit 0 ;;
  "issue comment")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "${GH_STUB_BODY:-/dev/null}" 2>/dev/null
      prev="$a"
    done
    exit 0 ;;
  "issue view")
    cat "${GH_STUB_COMMENTS:-/dev/null}" 2>/dev/null || echo '{"comments":[]}'
    exit 0 ;;
  "issue list")
    cat "${GH_STUB_ISSUES:-/dev/null}" 2>/dev/null || echo '[]'
    exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$bindir/gh"
  echo "$bindir"
}

# ── Case 1: post-handoff-comment.sh posts a marked comment ───────────
c1=$(new_repo case1)
bindir=$(install_gh_stub "$c1")
note="$c1/note.txt"
printf '→ Next action: write the test\n\nStopped mid-task.\n' > "$note"
log="$c1/gh.log"
GH_STUB_LOG="$log" GH_STUB_BODY="$c1/posted-body.txt" PATH="$bindir:$PATH" \
  bash "$REPO_ROOT/scripts/post-handoff-comment.sh" 251 feat/demo "$note" "$c1" \
  || fail "case 1 — post-handoff-comment.sh exited non-zero"
grep -q "issue comment 251" "$log" \
  || fail "case 1 — gh issue comment was not called for #251" "$(cat "$log")"
grep -q "<!-- arbo-handoff: feat/demo " "$c1/posted-body.txt" \
  || fail "case 1 — arbo-handoff marker not in the posted comment body" "$(cat "$c1/posted-body.txt" 2>/dev/null)"
ok "case 1 — post-handoff-comment.sh posts a comment to the issue"

# ── Case 2: handoff-commit-wip.sh wip-commits + pushes + reports SHA ──
c2=$(new_repo case2)
git -C "$c2" init -q --bare "$ROOT_TMP/case2-remote.git"
git -C "$c2" remote add origin "$ROOT_TMP/case2-remote.git"
git -C "$c2" push -q -u origin feat/demo
printf 'dirty\n' > "$c2/scratch.txt"          # make the tree dirty
sha=$(bash "$REPO_ROOT/scripts/handoff-commit-wip.sh" "$c2") \
  || fail "case 2 — handoff-commit-wip.sh exited non-zero"
[ -n "$sha" ] || fail "case 2 — script did not report the wip commit SHA"
git -C "$c2" log -1 --pretty=%s | grep -q '^wip: handoff' \
  || fail "case 2 — HEAD is not a 'wip: handoff' commit"
[ "$(git -C "$c2" rev-parse --short origin/feat/demo)" = "$sha" ] \
  || fail "case 2 — wip commit was not pushed to origin"
# clean tree → no-op
out=$(bash "$REPO_ROOT/scripts/handoff-commit-wip.sh" "$c2")
echo "$out" | grep -qi 'clean tree' \
  || fail "case 2 — clean tree should be a reported no-op" "$out"
# non-origin remote (e.g. only `upstream`) — must still push
c2u=$(new_repo case2u)
git -C "$c2u" init -q --bare "$ROOT_TMP/case2u-remote.git"
git -C "$c2u" remote add upstream "$ROOT_TMP/case2u-remote.git"
printf 'dirty\n' > "$c2u/scratch.txt"
ushaf=$(bash "$REPO_ROOT/scripts/handoff-commit-wip.sh" "$c2u") \
  || fail "case 2 — handoff-commit-wip.sh failed on a non-origin remote"
[ "$(git -C "$c2u" rev-parse --short upstream/feat/demo)" = "$ushaf" ] \
  || fail "case 2 — wip commit not pushed to the non-origin remote"
ok "case 2 — handoff-commit-wip.sh commits dirty work, pushes, no-ops when clean"

# ── Case 3: session-start.sh renders the handoff note ────────────────
c3="$ROOT_TMP/case3"
mkdir -p "$c3/.claude/hooks" "$c3/scripts" "$c3/.arboretum" "$c3/docs"
echo "# fixture" > "$c3/docs/ARCHITECTURE.md"
echo "# fixture" > "$c3/docs/REGISTER.md"
echo "# fixture" > "$c3/contracts.yaml"
echo "layer: 0" > "$c3/.arboretum.yml"
cp "$REPO_ROOT/.claude/hooks/session-start.sh" "$c3/.claude/hooks/"
git -C "$c3" init -q
git -C "$c3" config user.email f@e.com; git -C "$c3" config user.name f
git -C "$c3" config commit.gpgsign false
git -C "$c3" commit -q --allow-empty -m seed
git -C "$c3" remote add origin "https://github.com/example/repo.git"
# Stub refresh script so session-start.sh's cache-read block is entered.
printf '#!/usr/bin/env bash\nexit 0\n' > "$c3/scripts/refresh-next-cache.sh"
chmod +x "$c3/scripts/refresh-next-cache.sh"
cat > "$c3/.arboretum/next-cache.json" <<'JSON'
{ "fetched_at": "2026-05-17T00:00:00Z",
  "issue": { "number": 251, "title": "Session handoff", "url": "u",
             "body_first_lines": [], "body_empty": false,
             "labels": ["next-up"], "updated_at": "2026-05-17T00:00:00Z" },
  "handoff": { "posted_at": "2026-05-17T14:30:00Z", "branch": "feat/demo",
               "next_action": "write the RED smoke test",
               "body": "Stopped after wiring the cache." },
  "no_gh_remote": false, "error": null }
JSON
out=$(CLAUDE_PROJECT_DIR="$c3" bash "$c3/.claude/hooks/session-start.sh" 2>&1)
echo "$out" | grep -q '→ Next action: write the RED smoke test' \
  || fail "case 3 — handoff next-action line not rendered" "$out"
echo "$out" | grep -q 'Stopped after wiring the cache' \
  || fail "case 3 — handoff prose not rendered" "$out"
ok "case 3 — session-start.sh renders the handoff note"

# ── Case 4: Stop nudge — valid output, once per session ──────────────
c4=$(new_repo case4)
printf 'dirty\n' > "$c4/scratch.txt"
hook="$REPO_ROOT/hooks/stop-handoff-nudge.sh"
in='{"session_id":"s1","transcript_path":"/t/x.jsonl","cwd":"/t"}'
out1=$(echo "$in" | CLAUDE_PROJECT_DIR="$c4" bash "$hook")
# A `Stop` hook has no `additionalContext` / `hookSpecificOutput`
# channel — Claude Code rejects it. The advisory nudge must ride on
# the `systemMessage` common field and be valid JSON.
echo "$out1" | grep -q 'systemMessage' \
  || fail "case 4 — first Stop call should emit a systemMessage nudge" "$out1"
if echo "$out1" | grep -Eq 'additionalContext|hookSpecificOutput'; then
  fail "case 4 — Stop output must not use additionalContext/hookSpecificOutput" "$out1"
fi
echo "$out1" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  || fail "case 4 — Stop output is not valid JSON" "$out1"
[ -f "$c4/.arboretum/handoff-nudged" ] \
  || fail "case 4 — nudge marker not written"
# Second call, same session id → silent.
out2=$(echo "$in" | CLAUDE_PROJECT_DIR="$c4" bash "$hook")
[ -z "$out2" ] || fail "case 4 — second Stop call (same session) should be silent" "$out2"
# A new session id re-triggers the nudge: the marker is session-scoped,
# not "once ever" — nothing clears it between these two calls.
out2b=$(echo '{"session_id":"s2"}' | CLAUDE_PROJECT_DIR="$c4" bash "$hook")
echo "$out2b" | grep -q 'systemMessage' \
  || fail "case 4 — a new session id should re-trigger the nudge" "$out2b"
# done-marker also suppresses the nudge
c4b=$(new_repo case4b)
printf 'dirty\n' > "$c4b/scratch.txt"
mkdir -p "$c4b/.arboretum"; touch "$c4b/.arboretum/handoff-done"
out3=$(echo "$in" | CLAUDE_PROJECT_DIR="$c4b" bash "$hook")
[ -z "$out3" ] || fail "case 4 — handoff-done should suppress the nudge" "$out3"
# clean tree → silent (no in-flight work)
c4c=$(new_repo case4c)
out4=$(echo "$in" | CLAUDE_PROJECT_DIR="$c4c" bash "$hook")
[ -z "$out4" ] || fail "case 4 — clean tree should produce no nudge" "$out4"
# main branch → silent (even with a dirty tree)
c4d=$(new_repo case4d)
git -C "$c4d" checkout -q -B main
printf 'dirty\n' > "$c4d/scratch.txt"
out5=$(echo "$in" | CLAUDE_PROJECT_DIR="$c4d" bash "$hook")
[ -z "$out5" ] || fail "case 4 — main branch should produce no nudge" "$out5"
ok "case 4 — Stop nudge: valid systemMessage output, once per session"

# ── Case 5: SessionEnd flags un-handed-off uncommitted work ──────────
ehook="$REPO_ROOT/hooks/session-end-handoff-flag.sh"
# dirty feature branch → flag written
c5=$(new_repo case5)
printf 'dirty\n' > "$c5/scratch.txt"
echo '{"reason":"other"}' | CLAUDE_PROJECT_DIR="$c5" bash "$ehook"
[ -f "$c5/.arboretum/handoff-pending.json" ] \
  || fail "case 5 — handoff-pending.json not written for dirty tree"
grep -q '"branch"' "$c5/.arboretum/handoff-pending.json" \
  || fail "case 5 — flag missing branch field"
# clean tree → no flag
c5b=$(new_repo case5b)
echo '{"reason":"other"}' | CLAUDE_PROJECT_DIR="$c5b" bash "$ehook"
[ ! -f "$c5b/.arboretum/handoff-pending.json" ] \
  || fail "case 5 — clean tree should not be flagged"
# handoff-done → no flag
c5c=$(new_repo case5c)
printf 'dirty\n' > "$c5c/scratch.txt"
mkdir -p "$c5c/.arboretum"; touch "$c5c/.arboretum/handoff-done"
echo '{"reason":"other"}' | CLAUDE_PROJECT_DIR="$c5c" bash "$ehook"
[ ! -f "$c5c/.arboretum/handoff-pending.json" ] \
  || fail "case 5 — handoff-done should suppress the flag"
# main branch → no flag (even dirty)
c5d=$(new_repo case5d)
git -C "$c5d" checkout -q -B main
printf 'dirty\n' > "$c5d/scratch.txt"
echo '{"reason":"other"}' | CLAUDE_PROJECT_DIR="$c5d" bash "$ehook"
[ ! -f "$c5d/.arboretum/handoff-pending.json" ] \
  || fail "case 5 — main branch should not be flagged"
ok "case 5 — SessionEnd flags only un-handed-off uncommitted work"

# ── Case 6: SessionStart surfaces + clears the pending flag ──────────
c6="$ROOT_TMP/case6"
mkdir -p "$c6/.claude/hooks" "$c6/.arboretum" "$c6/docs"
echo "# fixture" > "$c6/docs/ARCHITECTURE.md"
echo "# fixture" > "$c6/docs/REGISTER.md"
echo "# fixture" > "$c6/contracts.yaml"
echo "layer: 0" > "$c6/.arboretum.yml"
cp "$REPO_ROOT/.claude/hooks/session-start.sh" "$c6/.claude/hooks/"
git -C "$c6" init -q
git -C "$c6" config user.email f@e.com; git -C "$c6" config user.name f
git -C "$c6" config commit.gpgsign false
git -C "$c6" commit -q --allow-empty -m seed
echo '{"branch":"feat/demo","ended_at":"2026-05-17T10:00:00Z"}' \
  > "$c6/.arboretum/handoff-pending.json"
touch "$c6/.arboretum/handoff-done" "$c6/.arboretum/handoff-nudged"
out=$(CLAUDE_PROJECT_DIR="$c6" bash "$c6/.claude/hooks/session-start.sh" 2>&1)
echo "$out" | grep -q 'left uncommitted work on feat/demo' \
  || fail "case 6 — pending-handoff warning not surfaced" "$out"
[ ! -f "$c6/.arboretum/handoff-pending.json" ] \
  || fail "case 6 — pending flag not cleared after surfacing"
[ ! -f "$c6/.arboretum/handoff-done" ] \
  || fail "case 6 — handoff-done marker not cleared at boot"
[ ! -f "$c6/.arboretum/handoff-nudged" ] \
  || fail "case 6 — handoff-nudged marker not cleared at boot"
ok "case 6 — SessionStart surfaces+clears the flag, clears per-session markers"

# ── Case 7: refresh-next-cache.sh parses the latest arbo-handoff comment ──
c7=$(new_repo case7)
git -C "$c7" remote add origin "https://github.com/example/repo.git"
bindir=$(install_gh_stub "$c7")
cat > "$c7/issues.json" <<'JSON'
[{"number":251,"title":"Session handoff v2","url":"https://github.com/example/repo/issues/251","body":"body","labels":[{"name":"next-up"}],"updatedAt":"2026-05-17T00:00:00Z"}]
JSON
cat > "$c7/comments.json" <<'JSON'
{"comments":[
  {"body":"<!-- arbo-handoff: feat/old 2026-05-16T08:00:00Z -->\n**Session handoff** · branch `feat/old` · 2026-05-16\n\n→ Next action: old action\n\nold prose.","createdAt":"2026-05-16T08:00:00Z"},
  {"body":"<!-- arbo-handoff: feat/demo 2026-05-17T14:30:00Z -->\n**Session handoff** · branch `feat/demo` · 2026-05-17\n\n→ Next action: write the parser test\n\nStopped after the cache wiring.","createdAt":"2026-05-17T14:30:00Z"},
  {"body":"a normal non-handoff comment","createdAt":"2026-05-17T15:00:00Z"},
  {"body":"discussion: a handoff comment begins with <!-- arbo-handoff: feat/decoy 2026-12-31T00:00:00Z --> as its first line","createdAt":"2026-12-31T23:59:59Z"}
]}
JSON
GH_STUB_ISSUES="$c7/issues.json" GH_STUB_COMMENTS="$c7/comments.json" PATH="$bindir:$PATH" \
  bash "$REPO_ROOT/scripts/refresh-next-cache.sh" "$c7"
cache="$c7/.arboretum/next-cache.json"
[ -f "$cache" ] || fail "case 7 — cache not written"
python3 - "$cache" <<'PY' || fail "case 7 — handoff parsed incorrectly" "$(cat "$cache")"
import json, sys
c = json.load(open(sys.argv[1]))
h = c.get("handoff")
assert h, "handoff key missing or null"
assert h["branch"] == "feat/demo", f"branch: {h}"
assert h["next_action"] == "write the parser test", f"next_action: {h}"
assert "Stopped after the cache wiring" in h["body"], f"body: {h}"
PY
ok "case 7 — refresh-next-cache.sh parses the latest arbo-handoff comment"

echo
echo "All handoff-v2 smoke-test cases passed."
exit 0
