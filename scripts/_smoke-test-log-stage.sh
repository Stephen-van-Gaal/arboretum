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
#
# `issue view --json labels` prints a JSON object whose `.labels` is built from
# SX_STUB_LABELS (newline-separated label names) so log-stage's stage-label
# swap (via roadmap_set_prefix_exclusive_label) sees a deterministic fixture
# set. `label list` and `label create` are stubbed so the exclusive-label
# helper's label-ensure path succeeds.
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
    # Build {"labels":[{"name":...},...]} from SX_STUB_LABELS (newline-sep),
    # then honor a trailing `--jq <filter>` the way real `gh` does so the
    # exclusive-label helper's `--jq '.labels[].name'` extraction works.
    labels_json=$(printf '%s' "${SX_STUB_LABELS:-}" \
      | jq -Rsc 'split("\n") | map(select(length > 0)) | {labels: map({name: .})}')
    jq_filter=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--jq" ] && jq_filter="$a"
      prev="$a"
    done
    if [ -n "$jq_filter" ]; then
      printf '%s' "$labels_json" | jq -r "$jq_filter"
    else
      printf '%s\n' "$labels_json"
    fi
    exit 0 ;;
  "label list")
    # Whatever labels the helper might check for: report them all present.
    printf '%s' "${SX_STUB_LABELS:-}" \
      | jq -Rsc 'split("\n") | map(select(length > 0)) | map({name: .})'
    exit 0 ;;
  "label create") exit 0 ;;
  "issue edit") exit 0 ;;
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

# ── Cases 4–5 removed: the --rewrite-body-only body rewriter no longer
#    exists (#570 — Operation 1 sets the stage:* label instead of editing
#    the issue body). Label-swap behaviour is covered by the full-run
#    cases below.

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

# ── Case 11: full invocation sets the stage:* label, posts the comment,
#            and performs NO body write (#570) ─────────────────────────
c11="$ROOT_TMP/case11"; mkdir -p "$c11"
bindir=$(install_gh_stub "$c11")
: > "$c11/gh.log"
SX_STUB_LABELS="stage:start" \
  GH_STUB_COMMENT_BODY="$c11/comment-body.out" \
  GH_STUB_LOG="$c11/gh.log" \
  LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
  PATH="$bindir:$PATH" \
  bash "$LOG_STAGE" 42 /design entered branch=feat/x \
    || fail "case 11 — log-stage exited non-zero" "$(cat "$c11/gh.log" 2>/dev/null)"

# stage:design is added and the prior stage:start removed in one edit call.
grep -q 'issue edit 42 --add-label stage:design --remove-label stage:start' "$c11/gh.log" \
  || fail "case 11 — did not set stage:design label" "$(cat "$c11/gh.log")"
# No body write of the ISSUE: an issue-body edit is `issue edit … --body-file`.
# (The journey-log comment legitimately uses `--body-file` on `issue comment`.)
grep -qE 'issue edit .*--body-file' "$c11/gh.log" \
  && fail "case 11 — performed an issue-body write (should be none)" "$(cat "$c11/gh.log")"
ok "case 11 — full run sets stage:* label, no body I/O"

# ── Case 12: full invocation also posts the log comment ──────────────
# Reuses case11's run (gh.log, comment-body.out from the same invocation).
grep -q "issue comment 42" "$c11/gh.log" \
  || fail "case 12 — expected 'gh issue comment 42'" "$(cat "$c11/gh.log")"
grep -q '<!-- pipeline-state:log -->' "$c11/comment-body.out" \
  || fail "case 12 — comment body missing log marker" "$(cat "$c11/comment-body.out")"
grep -qE '^- 2026-05-23T14:03:00Z — /design entered, branch: feat/x$' "$c11/comment-body.out" \
  || fail "case 12 — comment body does not match D5 line shape" "$(cat "$c11/comment-body.out")"
ok "case 12 — full invocation posts D5-shaped log comment"

# ── Case 13: the removed `repair` action is now rejected (vocab 7→6) ──
if bash "$LOG_STAGE" 42 /design repair 2>/dev/null; then
  fail "case 13 — repair action should be rejected"
else
  ok "case 13 — repair action rejected (vocab 7->6)"
fi

# ── Case 13b: a malformed stage token is rejected before any label write ──
# (reviewer finding #570 — log-stage must not create a garbage stage:* label).
if bash "$LOG_STAGE" 42 /build2 entered 2>/dev/null; then
  fail "case 13b — malformed stage /build2 should be rejected"
else
  ok "case 13b — malformed stage token rejected (no garbage label)"
fi

# ── Case 14: --dry-run prints the would-do summary; calls no gh ──────
c14="$ROOT_TMP/case14"; mkdir -p "$c14"
bindir=$(install_gh_stub "$c14")
out=$(SX_STUB_LABELS="stage:start" \
      GH_STUB_LOG="$c14/gh.log" \
      LOG_STAGE_TS_OVERRIDE="2026-05-23T14:03:00Z" \
      PATH="$bindir:$PATH" \
      bash "$LOG_STAGE" --dry-run 307 /design entered branch=feat/foo 2>&1) \
    || fail "case 14 — --dry-run exited non-zero" "$out"

# Output mentions both ops it would perform.
echo "$out" | grep -qiE 'would.*set exclusive label stage:design.*307' \
  || fail "case 14 — dry-run output should describe the stage-label it would set" "$out"
echo "$out" | grep -qiE 'would.*tracker issue comment.*307' \
  || fail "case 14 — dry-run output should describe the comment-post it would do" "$out"
echo "$out" | grep -qF -- '- 2026-05-23T14:03:00Z — /design entered, branch: feat/foo' \
  || fail "case 14 — dry-run should show the log line it would post" "$out"
# No gh WRITE call happened (auth status + label list are OK; edit/comment are not).
grep -qE '^issue (edit|comment)' "$c14/gh.log" \
  && fail "case 14 — --dry-run must not call gh issue edit/comment" "$(cat "$c14/gh.log")"
ok "case 14 — --dry-run prints summary, calls no gh write ops"

# ── Case 15: stage-label write failure surfaces exit 2 + named-op message ──
c15="$ROOT_TMP/case15"; mkdir -p "$c15"
# Custom stub that fails on `issue edit` (the label swap) but succeeds on
# auth/label-read so Operation 1's exclusive-label set is what fails.
bindir15="$c15/.bin"; mkdir -p "$bindir15"
cat > "$bindir15/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}") printf 'owner/repo\n'; exit 0 ;;
  "issue view") echo '{"labels":[{"name":"stage:start"}]}'; exit 0 ;;
  "label list") echo '[]'; exit 0 ;;
  "label create") exit 0 ;;
  "issue edit") exit 1 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$bindir15/gh"
set +e
out=$(PATH="$bindir15:$PATH" bash "$LOG_STAGE" 307 /design entered 2>&1)
ec=$?
set -e
[ "$ec" -eq 2 ] || fail "case 15 — expected exit 2 on stage-label failure (got $ec)" "$out"
echo "$out" | grep -qiE 'stage label.*fail' \
  || fail "case 15 — expected message naming stage-label failure" "$out"
ok "case 15 — stage-label write failure exits 2 with named-op message"

# ── Case 16: comment-post failure surfaces exit 3 + partial-state warning ──
c16="$ROOT_TMP/case16"; mkdir -p "$c16"
bindir16="$c16/.bin"; mkdir -p "$bindir16"
cat > "$bindir16/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}") printf 'owner/repo\n'; exit 0 ;;
  "issue view") echo '{"labels":[{"name":"stage:start"}]}'; exit 0 ;;
  "label list") echo '[]'; exit 0 ;;
  "label create") exit 0 ;;
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
ok "case 16 — comment-post failure exits 3 with partial-state warning"

echo
echo "log-stage smoke tests (subset) passed."
exit 0
