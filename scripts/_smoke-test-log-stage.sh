#!/usr/bin/env bash
# owner: pipeline-state-tracking
# _smoke-test-log-stage.sh — Verify scripts/log-stage.sh against WS9
# design (docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws9-state-tracking-design.md).
# Usage: bash scripts/_smoke-test-log-stage.sh
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_STAGE="$REPO_ROOT/scripts/log-stage.sh"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# A gh stub: dispatches on $1 $2, logs every call.
install_gh_stub() {
  local bindir="$1/.bin"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${GH_STUB_LOG:-/dev/null}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}")
    printf 'owner/repo\n'
    exit 0 ;;
  "issue view")
    cat "${GH_STUB_BODY:-/dev/null}" 2>/dev/null || echo '{"body":""}'
    exit 0 ;;
  "issue edit")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "${GH_STUB_EDIT_BODY:-/dev/null}" 2>/dev/null
      prev="$a"
    done
    exit 0 ;;
  "issue comment")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "${GH_STUB_COMMENT_BODY:-/dev/null}" 2>/dev/null
      prev="$a"
    done
    exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$bindir/gh"
  echo "$bindir"
}

# ── Case 1: missing args → non-zero exit + usage to stderr ───────────
c1="$ROOT_TMP/case1"; mkdir -p "$c1"  # pre-allocated; reserved for stub wiring in later cases
out=$(bash "$LOG_STAGE" 2>&1) && fail "case 1 — no args should fail" "$out"
echo "$out" | grep -q -iE 'usage|issue number|stage|action' \
  || fail "case 1 — expected usage hint in error output" "$out"
ok "case 1 — missing args exit non-zero with usage"

# ── Case 2: invalid action → non-zero exit, names valid vocab ────────
out=$(bash "$LOG_STAGE" 307 /design notarealaction 2>&1) \
  && fail "case 2 — invalid action should fail" "$out"
echo "$out" | grep -qiE 'invalid action|entered.*exited.*skipped' \
  || fail "case 2 — expected error naming valid actions" "$out"
ok "case 2 — invalid action exits non-zero with vocab hint"

# ── Case 3: each of the 7 valid actions is accepted (dry-run; no gh) ─
# Anticipates Task 9's --dry-run flag — defer this case until Task 9.

# ── Case 4: header write preserves non-marker body content ───────────
# Use a unit-level helper invocation: write a body to a fixture file,
# call the script's internal rewrite function via a documented subcommand
# (we expose `--rewrite-body-only <body-file> <stage>` for testing).
c4="$ROOT_TMP/case4"; mkdir -p "$c4"
cat > "$c4/body.in" <<'BODY'
## Context

Existing issue body with multiple paragraphs.

- bullet one
- bullet two

End.
BODY
out=$(bash "$LOG_STAGE" --rewrite-body-only "$c4/body.in" /design) \
  || fail "case 4 — --rewrite-body-only exited non-zero"
echo "$out" | grep -q '<!-- pipeline-state:current-stage -->' \
  || fail "case 4 — opening marker missing" "$out"
echo "$out" | grep -q '\*\*Current stage:\*\* /design' \
  || fail "case 4 — stage line missing" "$out"
echo "$out" | grep -q '<!-- /pipeline-state:current-stage -->' \
  || fail "case 4 — closing marker missing" "$out"
echo "$out" | grep -q '## Context' \
  || fail "case 4 — original body content not preserved" "$out"
# -Fe: fixed-string + explicit-pattern marker, prevents leading `-` from being read as a flag (cross-grep/ugrep portability).
echo "$out" | grep -qFe '- bullet two' \
  || fail "case 4 — bullet list not preserved" "$out"
# First three lines must be the marker block (header is at TOP per D3).
head -3 <<<"$out" | grep -q '<!-- pipeline-state:current-stage -->' \
  || fail "case 4 — marker block must be at top of body" "$(head -5 <<<"$out")"
ok "case 4 — header write preserves non-marker body content (D3)"

# ── Case 5: re-write replaces existing marker block, not appends ─────
c5="$ROOT_TMP/case5"; mkdir -p "$c5"
cat > "$c5/body.in" <<'BODY'
<!-- pipeline-state:current-stage -->
**Current stage:** /design
<!-- /pipeline-state:current-stage -->

## Context

Issue body.
BODY
out=$(bash "$LOG_STAGE" --rewrite-body-only "$c5/body.in" /build)
# Exactly one marker block; new stage value present; old stage value absent.
[ "$(grep -c '<!-- pipeline-state:current-stage -->' <<<"$out")" -eq 1 ] \
  || fail "case 5 — should be exactly one opening marker after rewrite" "$out"
echo "$out" | grep -q '\*\*Current stage:\*\* /build' \
  || fail "case 5 — new stage value missing" "$out"
echo "$out" | grep -q '\*\*Current stage:\*\* /design' \
  && fail "case 5 — old stage value should be gone" "$out"
ok "case 5 — re-write replaces marker block in place"

# ── Case 6: --emit-log-only prints the exact D5 line shape ───────────
c6="$ROOT_TMP/case6"; mkdir -p "$c6"
out=$(LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      bash "$LOG_STAGE" --emit-log-only /design entered branch=feat/foo spec=docs/foo.md)
# Marker line + log line.
head -1 <<<"$out" | grep -q '^<!-- pipeline-state:log -->$' \
  || fail "case 6 — first line should be the log marker" "$out"
sed -n '2p' <<<"$out" \
  | grep -qE '^- 2026-05-23T14:03:00Z — /design entered, branch: feat/foo, spec: docs/foo\.md$' \
  || fail "case 6 — log line does not match expected D5 shape" "$out"
ok "case 6 — log emitter produces exact D5 line shape"

# ── Case 7: action with no context pairs produces no trailing comma ──
out=$(LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      bash "$LOG_STAGE" --emit-log-only /design exited)
sed -n '2p' <<<"$out" \
  | grep -qE '^- 2026-05-23T14:03:00Z — /design exited$' \
  || fail "case 7 — no-context line shape wrong (trailing comma?)" "$out"
ok "case 7 — no-context log line is clean"

# ── Case 8: value with `, ` is double-quoted ─────────────────────────
out=$(LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      bash "$LOG_STAGE" --emit-log-only /handoff summary \
        'summary=Drafted D5; blocked on schema, ran out of context')
sed -n '2p' <<<"$out" \
  | grep -qE '^- 2026-05-23T14:03:00Z — /handoff summary, summary: "Drafted D5; blocked on schema, ran out of context"$' \
  || fail "case 8 — value with comma should be double-quoted" "$out"
ok "case 8 — value containing comma-space is double-quoted"

# ── Case 9: literal " is escaped as \" inside quoted value ───────────
out=$(LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      bash "$LOG_STAGE" --emit-log-only /design entered \
        'summary=She said "hello", then left')
sed -n '2p' <<<"$out" \
  | grep -qE 'summary: "She said \\"hello\\", then left"$' \
  || fail "case 9 — embedded double-quotes should be backslash-escaped" "$out"
ok "case 9 — embedded double-quotes escaped"

# ── Case 10: literal backslash is escaped as \\ ──────────────────────
out=$(LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      bash "$LOG_STAGE" --emit-log-only /design entered \
        'path=C:\Users\foo, x=y')
sed -n '2p' <<<"$out" \
  | grep -qE 'path: "C:\\\\Users\\\\foo, x=y"$' \
  || fail "case 10 — embedded backslashes should be doubled" "$out"
ok "case 10 — embedded backslashes escaped as doubled"

# ── Case 11: full invocation writes new body via gh issue edit ───────────
c11="$ROOT_TMP/case11"; mkdir -p "$c11"
bindir=$(install_gh_stub "$c11")
cat > "$c11/issue-body.json" <<'JSON'
{"body": "## Context\n\nExisting body.\n"}
JSON
GH_STUB_BODY="$c11/issue-body.json" \
  GH_STUB_EDIT_BODY="$c11/edit-body.out" \
  GH_STUB_COMMENT_BODY="$c11/comment-body.out" \
  GH_STUB_LOG="$c11/gh.log" \
  LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
  PATH="$bindir:$PATH" \
  bash "$LOG_STAGE" 307 /design entered branch=feat/foo \
    || fail "case 11 — log-stage exited non-zero" "$(cat "$c11/gh.log" 2>/dev/null)"

# gh issue view 307 was called (to read current body).
grep -q "issue view 307" "$c11/gh.log" \
  || fail "case 11 — expected 'gh issue view 307' to read body" "$(cat "$c11/gh.log")"

# gh issue edit 307 --body-file ... was called with rewritten body.
grep -q "issue edit 307" "$c11/gh.log" \
  || fail "case 11 — expected 'gh issue edit 307'" "$(cat "$c11/gh.log")"
grep -q '<!-- pipeline-state:current-stage -->' "$c11/edit-body.out" \
  || fail "case 11 — written body missing header marker" "$(cat "$c11/edit-body.out")"
grep -q '\*\*Current stage:\*\* /design' "$c11/edit-body.out" \
  || fail "case 11 — written body missing stage line" "$(cat "$c11/edit-body.out")"
grep -q '## Context' "$c11/edit-body.out" \
  || fail "case 11 — written body did not preserve original content" "$(cat "$c11/edit-body.out")"
ok "case 11 — full invocation reads body, rewrites header, writes back"

# ── Case 12: full invocation also posts the log comment ──────────────
# Reuses case11's fixture (gh.log, comment-body.out from the same run).
grep -q "issue comment 307" "$c11/gh.log" \
  || fail "case 12 — expected 'gh issue comment 307'" "$(cat "$c11/gh.log")"
grep -q '<!-- pipeline-state:log -->' "$c11/comment-body.out" \
  || fail "case 12 — comment body missing log marker" "$(cat "$c11/comment-body.out")"
grep -qE '^- 2026-05-23T14:03:00Z — /design entered, branch: feat/foo$' "$c11/comment-body.out" \
  || fail "case 12 — comment body does not match D5 line shape" "$(cat "$c11/comment-body.out")"
ok "case 12 — full invocation posts D5-shaped log comment"

# ── Case 13: malformed marker block triggers rebuild + repair log ────
c13="$ROOT_TMP/case13"; mkdir -p "$c13"
bindir=$(install_gh_stub "$c13")
# Body has an OPENING marker but no closing marker (truncated by hand-edit).
# The fixture deliberately uses bare-body shape (not JSON-wrapped) so the
# malformed-marker grep detection works the same way it will in production.
cat > "$c13/issue-body.json" <<'JSON'
"<!-- pipeline-state:current-stage -->\n**Current stage:** /design\n\n## Context\n\nBody continues without close marker.\n"
JSON
GH_STUB_BODY="$c13/issue-body.json" \
  GH_STUB_EDIT_BODY="$c13/edit-body.out" \
  GH_STUB_COMMENT_BODY="$c13/comment-body.out" \
  GH_STUB_LOG="$c13/gh.log" \
  LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
  PATH="$bindir:$PATH" \
  bash "$LOG_STAGE" 307 /build entered branch=feat/foo \
    || fail "case 13 — repair flow should still exit 0" "$(cat "$c13/gh.log" 2>/dev/null)"

# Rebuilt body has a well-formed marker block: opening AND closing marker.
grep -q '<!-- /pipeline-state:current-stage -->' "$c13/edit-body.out" \
  || fail "case 13 — closing marker missing from rebuilt body" "$(cat "$c13/edit-body.out")"
[ "$(grep -c '<!-- pipeline-state:current-stage -->' "$c13/edit-body.out")" -eq 1 ] \
  || fail "case 13 — expected exactly one opening marker after rebuild" "$(cat "$c13/edit-body.out")"
grep -q '## Context' "$c13/edit-body.out" \
  || fail "case 13 — original body content lost during repair" "$(cat "$c13/edit-body.out")"

# TWO 'issue comment 307' calls in gh.log — one for repair, one for entered.
[ "$(grep -c "issue comment 307" "$c13/gh.log")" -ge 2 ] \
  || fail "case 13 — expected at least 2 comment posts (repair + entered)" "$(cat "$c13/gh.log")"
ok "case 13 — malformed marker triggers rebuild + repair log comment"

# ── Case 14: --dry-run prints the would-do summary; calls no gh ──────
c14="$ROOT_TMP/case14"; mkdir -p "$c14"
bindir=$(install_gh_stub "$c14")
cat > "$c14/issue-body.json" <<'JSON'
{"body": "existing\n"}
JSON
out=$(GH_STUB_BODY="$c14/issue-body.json" \
      GH_STUB_LOG="$c14/gh.log" \
      LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      PATH="$bindir:$PATH" \
      bash "$LOG_STAGE" --dry-run 307 /design entered branch=feat/foo 2>&1) \
    || fail "case 14 — --dry-run exited non-zero" "$out"

# Output mentions both ops it would perform.
echo "$out" | grep -qiE 'would.*tracker issue update.*307' \
  || fail "case 14 — dry-run output should describe the body-edit it would do" "$out"
echo "$out" | grep -qiE 'would.*tracker issue comment.*307' \
  || fail "case 14 — dry-run output should describe the comment-post it would do" "$out"
echo "$out" | grep -qF -- '- 2026-05-23T14:03:00Z — /design entered, branch: feat/foo' \
  || fail "case 14 — dry-run should show the log line it would post" "$out"
# No gh WRITE call happened (auth status + issue view are OK; edit/comment are not).
grep -qE '^issue (edit|comment)' "$c14/gh.log" \
  && fail "case 14 — --dry-run must not call gh issue edit/comment" "$(cat "$c14/gh.log")"
ok "case 14 — --dry-run prints summary, calls no gh write ops"

# ── Case 15: body-edit failure surfaces exit 2 + named-op message ────
c15="$ROOT_TMP/case15"; mkdir -p "$c15"
# Custom stub that fails on `issue edit` but succeeds on `auth status` and `issue view`.
bindir15="$c15/.bin"; mkdir -p "$bindir15"
cat > "$bindir15/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}") printf 'owner/repo\n'; exit 0 ;;
  "issue view") echo '{"body":""}'; exit 0 ;;
  "issue edit") exit 1 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$bindir15/gh"
set +e
out=$(PATH="$bindir15:$PATH" bash "$LOG_STAGE" 307 /design entered 2>&1)
ec=$?
set -e
[ "$ec" -eq 2 ] || fail "case 15 — expected exit 2 on body-edit failure (got $ec)" "$out"
echo "$out" | grep -qiE 'body-edit.*fail|header write.*fail' \
  || fail "case 15 — expected message naming body-edit/header-write failure" "$out"
ok "case 15 — body-edit failure exits 2 with named-op message"

# ── Case 16: comment-post failure surfaces exit 3 + partial-state warning ──
c16="$ROOT_TMP/case16"; mkdir -p "$c16"
bindir16="$c16/.bin"; mkdir -p "$bindir16"
cat > "$bindir16/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}") printf 'owner/repo\n'; exit 0 ;;
  "issue view") echo '{"body":""}'; exit 0 ;;
  "issue edit") exit 0 ;;
  "issue comment") exit 1 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$bindir16/gh"
set +e
out=$(PATH="$bindir16:$PATH" bash "$LOG_STAGE" 307 /design entered 2>&1)
ec=$?
set -e
[ "$ec" -eq 3 ] || fail "case 16 — expected exit 3 on comment-post failure (got $ec)" "$out"
echo "$out" | grep -qiE 'comment-post.*fail|log entry.*fail' \
  || fail "case 16 — expected message naming comment-post failure" "$out"
echo "$out" | grep -qiE 'body-edit already applied' \
  || fail "case 16 — expected partial-state warning (body-edit succeeded, comment-post failed)" "$out"
ok "case 16 — comment-post failure exits 3 with partial-state warning"

echo
echo "log-stage smoke tests (subset) passed."
exit 0
