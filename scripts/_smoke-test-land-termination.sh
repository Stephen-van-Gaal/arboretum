#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-land-termination.sh — Verify /land's three-phase handler
# enforces the termination contract per
# docs/superpowers/specs/2026-05-28-land-loop-termination-design.md.
#
# /land itself is a markdown procedure, not executable code. This smoke
# test exercises the bash helpers the procedure invokes — terminal-
# state detection, stall detection, and the ScheduleWakeup gate — to
# pin the contract at the helper layer where it can be tested directly.
#
# Usage: bash scripts/_smoke-test-land-termination.sh
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPERS="$REPO_ROOT/scripts/land-handler.sh"  # created in Step 3
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

# Disable the fetch retry sleep so the not-found case isn't slow.
export FETCH_RETRY_SLEEP=0

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

PR_SKILL="$REPO_ROOT/skills/pr/SKILL.md"
FINISH_SKILL="$REPO_ROOT/skills/finish/SKILL.md"
LAND_SKILL="$REPO_ROOT/skills/land/SKILL.md"
CLEANUP_SKILL="$REPO_ROOT/skills/cleanup/SKILL.md"
REFLECT_SKILL="$REPO_ROOT/skills/reflect/SKILL.md"
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"
SETTINGS_TEMPLATE="$REPO_ROOT/docs/templates/settings.json.template"
CLOSURE_HELPER="$REPO_ROOT/scripts/cleanup-tracker-closure.sh"

# ── Case 0: Shipping skills dispatch on backend before provider calls ─
grep -q 'SHIP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"' "$PR_SKILL" \
  || fail "case 0a — /pr does not read the configured backend"
grep -Fq 'git rev-parse --show-toplevel 2>/dev/null' "$PR_SKILL" \
  || fail "case 0a — /pr does not resolve backend from the active worktree first"
grep -q 'az repos pr create' "$PR_SKILL" \
  || fail "case 0a — /pr does not document Azure Repos PR creation"
grep -Fq '_links.web.href' "$PR_SKILL" \
  || fail "case 0a — /pr does not prefer Azure Repos web links over REST URLs"
grep -q 'roadmap_ado_organization' "$PR_SKILL" \
  || fail "case 0a — /pr fallback URL does not use active ADO organization config"
grep -q 'repository",{}).get("project",{}).get("name"' "$PR_SKILL" \
  || fail "case 0a — /pr fallback URL does not use PR project metadata"
grep -q 'scripts/refresh-stage-cache.sh' "$PR_SKILL" \
  || fail "case 0a — /pr does not reuse the stage-cache branch slug convention"
grep -q 'Closes #<issue>' "$PR_SKILL" \
  || fail "case 0a — /pr does not render GitHub close intent in the Tracker section"
grep -q 'Closure verification: pending post-merge cleanup' "$PR_SKILL" \
  || fail "case 0a — /pr does not surface pending ADO cleanup verification"
grep -q 'Do not auto-close epics' "$PR_SKILL" \
  || fail "case 0a — /pr does not guard epics from automatic close intent"
ok "case 0a — /pr has GitHub/Azure backend dispatch"

grep -q 'SHIP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"' "$FINISH_SKILL" \
  || fail "case 0b — /finish does not read the configured backend"
grep -Fq 'git rev-parse --show-toplevel 2>/dev/null' "$FINISH_SKILL" \
  || fail "case 0b — /finish does not resolve backend from the active worktree first"
grep -Fq 'PIPELINE="$(cd "$PROJECT_DIR" && bash "$PROJECT_DIR/scripts/read-pipeline-flag.sh")"' "$FINISH_SKILL" \
  || fail "case 0b — /finish does not read the pipeline flag from the resolved project root"
grep -q 'backend-aware `/pr`' "$FINISH_SKILL" \
  || fail "case 0b — /finish ship tail does not name backend-aware /pr"
grep -q 'Tracker closure intent:' "$FINISH_SKILL" \
  || fail "case 0b — /finish does not audit tracker closure intent before /pr"
grep -q '`/land` is merge-readiness-only' "$FINISH_SKILL" \
  || fail "case 0b — /finish does not keep /land out of tracker closure"
ok "case 0b — /finish carries backend-aware ship tail"

grep -q 'LAND_BACKEND="${SHIP_BACKEND:-$(roadmap_backend "$PROJECT_DIR")}"' "$LAND_SKILL" \
  || fail "case 0c — /land does not read the configured backend"
grep -Fq 'git rev-parse --show-toplevel 2>/dev/null' "$LAND_SKILL" \
  || fail "case 0c — /land does not resolve backend from the active worktree first"
grep -q 'Do not call `gh pr view`' "$LAND_SKILL" \
  || fail "case 0c — /land does not guard Azure DevOps from GitHub PR commands"
grep -q 'az repos pr policy list' "$LAND_SKILL" \
  || fail "case 0c — /land does not document Azure policy checks"
grep -q 'BLOCKING_POLICY_FAILURES' "$LAND_SKILL" \
  || fail "case 0c — /land does not filter ADO policy failures to blocking policies"
grep -q 'Stop here unless the user has explicitly confirmed' "$LAND_SKILL" \
  || fail "case 0c — /land does not gate ADO merge handoff on human reviewer-thread confirmation"
grep -q 'sourceRefName' "$LAND_SKILL" \
  || fail "case 0c — /land does not classify the actual Azure Repos source ref"
grep -q 'targetRefName' "$LAND_SKILL" \
  || fail "case 0c — /land does not classify the actual Azure Repos target ref"
grep -Fq '+refs/heads/$SOURCE_BRANCH:refs/remotes/$REMOTE/$SOURCE_BRANCH' "$LAND_SKILL" \
  || fail "case 0c — /land does not force-refresh ADO source refs before classification"
if grep -q 'git diff "$BASE"...HEAD' "$LAND_SKILL"; then
  fail "case 0c — /land still classifies ADO PRs from local HEAD"
fi
ok "case 0c — /land routes Azure DevOps away from GitHub handler"

grep -q 'CLEANUP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not read the configured backend"
grep -q 'roadmap_require_backend "$CLEANUP_BACKEND"' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not check selected backend prerequisites"
grep -q 'az repos pr list' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not document Azure Repos merged-PR lookup"
grep -q -- '--status completed' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not use Azure Repos completed PR state"
grep -q 'do not fall back to GitHub' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not guard ADO cleanup from GitHub fallback"
grep -q 'case "$MERGED_PR_COUNT" in' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not require exactly one merged/completed PR for the branch"
grep -q 'Found multiple merged/completed PRs for branch' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not stop on ambiguous branch-to-PR matches"
grep -q 'roadmap_tracker_pr_show "$MERGED_PR_NUMBER" --json number,body,state,mergedAt' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not read merged PR metadata through the neutral helper"
[ -f "$CLOSURE_HELPER" ] \
  || fail "case 0d — /cleanup closure helper is missing"
grep -q 'scripts/cleanup-tracker-closure.sh classify' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not classify tracker closure through the cleanup helper"
grep -q 'scripts/cleanup-tracker-closure.sh close' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not close tracker items through the cleanup helper"
grep -q -- '--confirm-close' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not require explicit close confirmation"
grep -q 'roadmap_tracker_pr_closure_status "$pr" "$issue"' "$CLOSURE_HELPER" \
  || fail "case 0d — cleanup helper does not use the neutral PR closure-status helper"
grep -q 'roadmap_tracker_issue_close' "$CLOSURE_HELPER" \
  || fail "case 0d — cleanup helper does not close through the neutral issue helper"
grep -q -- '--reason completed' "$CLOSURE_HELPER" \
  || fail "case 0d — cleanup helper does not close with the completed reason"
grep -q 'status=unsupported' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not surface unsupported closure verification"
grep -q 'cleanup-merged-session.sh' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not delegate local destructive cleanup to helper"
grep -q 'git pull --ff-only' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not require ff-only main sync"
grep -q 'active session worktree' "$CLEANUP_SKILL" \
  || fail "case 0d — /cleanup does not document active worktree terminal behavior"
grep -Fq '"Bash(bash scripts/cleanup-merged-session.sh *)"' "$SETTINGS_JSON" \
  || fail "case 0d — project settings do not allow the cleanup helper"
grep -Fq '"Bash(bash scripts/cleanup-merged-session.sh *)"' "$SETTINGS_TEMPLATE" \
  || fail "case 0d — settings template does not allow the cleanup helper"
ok "case 0d — /cleanup has GitHub/Azure backend dispatch"

grep -q 'REFLECT_BACKEND="$(roadmap_backend "$PROJECT_DIR")"' "$REFLECT_SKILL" \
  || fail "case 0e — /reflect does not read the configured backend"
grep -q 'roadmap_require_backend "$REFLECT_BACKEND"' "$REFLECT_SKILL" \
  || fail "case 0e — /reflect does not check selected backend prerequisites"
grep -q 'az repos pr list --status completed --top 1 --output json' "$REFLECT_SKILL" \
  || fail "case 0e — /reflect does not document Azure Repos completed-PR lookup"
grep -q 'configured tracker backend' "$REFLECT_SKILL" \
  || fail "case 0e — /reflect does not delegate next-up to the configured tracker backend"
if grep -q 'manages the GitHub `next-up` label' "$REFLECT_SKILL"; then
  fail "case 0e — /reflect still describes next-up as GitHub-specific"
fi
ok "case 0e — /reflect has GitHub/Azure backend dispatch"

# A gh stub that takes its responses from env vars. The stub uses jq
# output for "repo view --json nameWithOwner --jq .nameWithOwner" which
# the caller invokes to resolve the repo owner/name. Branches API and
# reviews API are stubbed independently.
BINDIR="$ROOT_TMP/.bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view")
    # If GH_STUB_PR_VIEW_FAIL is set, simulate a fetch failure with
    # the given stderr text (used for not-found / transient cases).
    if [ -n "${GH_STUB_PR_VIEW_FAIL:-}" ]; then
      printf '%s\n' "$GH_STUB_PR_VIEW_FAIL" >&2
      exit 1
    fi
    cat "${GH_STUB_PR_VIEW:-/dev/null}"
    exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*)
        # Emit a 404-classified stderr when the test signals deletion,
        # so head_branch_exists sees a confirmed 404 (not a transient).
        if [ "${GH_STUB_BRANCH_EXIT:-0}" != "0" ]; then
          printf 'gh: Not Found (HTTP 404)\n' >&2
        fi
        exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks") cat "${GH_STUB_PR_CHECKS:-/dev/null}"; exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
PATH="$BINDIR:$PATH"; export PATH

# Journey-log author trust (#249). The fixture log comments below are authored
# by the allowlisted `trusted-bot`; point read-journey-log (invoked transitively
# by land-handler) at a present-key config that allowlists it, so strict-mode
# filtering surfaces the legitimate entries this test relies on.
cat > "$ROOT_TMP/trust.yml" <<'YML'
trust:
  journey_log_authors:
    - trusted-bot
YML
export TRUST_CONFIG_OVERRIDE="$ROOT_TMP/trust.yml"

# Default empty-reviews fixture used by most cases.
cat > "$ROOT_TMP/reviews-empty.json" <<'JSON'
[]
JSON

# ── Case 1: Cold + terminal (MERGED) → terminal=true, no wake-up ──────
cat > "$ROOT_TMP/pr-merged.json" <<'JSON'
{"number": 999, "state": "MERGED", "headRefName": "feat/x", "isDraft": false}
JSON
cat > "$ROOT_TMP/comments-empty.json" <<'JSON'
[]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-merged.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      WAKEUP_LOG="$ROOT_TMP/wakeups.log" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 1 — handler should not error on MERGED" "$out"
echo "$out" | grep -q 'terminal=true' \
  || fail "case 1 — expected terminal=true" "$out"
echo "$out" | grep -q 'reason=merged' \
  || fail "case 1 — expected reason=merged" "$out"
[ ! -s "$ROOT_TMP/wakeups.log" ] \
  || fail "case 1 — no wake-up should be queued on terminal" "$(cat $ROOT_TMP/wakeups.log)"
ok "case 1 — cold+terminal returns terminal=true with no wake-up"

# ── Case 2: Cold + terminal (CLOSED) → same shape ─────────────────────
cat > "$ROOT_TMP/pr-closed.json" <<'JSON'
{"number": 999, "state": "CLOSED", "headRefName": "feat/x", "isDraft": false}
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-closed.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      WAKEUP_LOG="$ROOT_TMP/wakeups.log" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 2 — handler should not error on CLOSED" "$out"
echo "$out" | grep -q 'reason=closed' \
  || fail "case 2 — expected reason=closed" "$out"
ok "case 2 — cold+terminal CLOSED returns terminal=true"

# ── Case 3: Active (OPEN) → terminal=false ────────────────────────────
cat > "$ROOT_TMP/pr-open.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": false}
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 3 — handler should not error on OPEN" "$out"
echo "$out" | grep -q 'terminal=false' \
  || fail "case 3 — expected terminal=false" "$out"
ok "case 3 — active state returns terminal=false"

# ── Case 4: Warm + terminal — prior journey-log entry exists ──────────
cat > "$ROOT_TMP/comments-with-phase3.json" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T11:00:00Z — /land summary, phase: 3, head_sha: abc1234, head_sha_unchanged_count: 0"}
]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-merged.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-with-phase3.json" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 4 — handler should not error" "$out"
echo "$out" | grep -q 'terminal=true' \
  || fail "case 4 — expected terminal=true" "$out"
echo "$out" | grep -q 'entry=warm' \
  || fail "case 4 — expected entry=warm given prior /land summary entry" "$out"
ok "case 4 — warm+terminal differentiation works"

# ── Case 5: Phase 2 draft → stall=true, reason=draft ──────────────────
cat > "$ROOT_TMP/pr-draft.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": true}
JSON
cat > "$ROOT_TMP/checks-empty.json" <<'JSON'
[]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-draft.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-empty.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 5 — handler should not error on draft" "$out"
echo "$out" | grep -q 'stall=true' \
  || fail "case 5 — expected stall=true" "$out"
echo "$out" | grep -q 'reason=draft' \
  || fail "case 5 — expected reason=draft" "$out"
ok "case 5 — draft PR triggers stall=true reason=draft"

# ── Case 6: Open + not draft + CI green → stall=false ─────────────────
cat > "$ROOT_TMP/checks-green.json" <<'JSON'
[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 6 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 6 — expected stall=false" "$out"
ok "case 6 — open + green PR is not stalled"

# ── Case 7: Head-SHA stall counter — prior entry has count=1, same SHA ─
cat > "$ROOT_TMP/pr-open-sha.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": false, "headRefOid": "deadbeef1234"}
JSON
cat > "$ROOT_TMP/comments-prior-count1.json" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T11:00:00Z — /land summary, phase: 3, head_sha: deadbeef1234, head_sha_unchanged_count: 1"}
]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 7 — handler should not error" "$out"
echo "$out" | grep -q 'stall=true' \
  || fail "case 7 — expected stall=true" "$out"
echo "$out" | grep -q 'reason=head-sha-unchanged' \
  || fail "case 7 — expected reason=head-sha-unchanged" "$out"
echo "$out" | grep -q 'head_sha_unchanged_count=2' \
  || fail "case 7 — expected new count=2" "$out"
ok "case 7 — head-SHA stall counter trips at 2"

# ── Case 8: Same fixture, but prior count=0 — should NOT stall ────────
cat > "$ROOT_TMP/comments-prior-count0.json" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T11:00:00Z — /land summary, phase: 3, head_sha: deadbeef1234, head_sha_unchanged_count: 0"}
]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count0.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 8 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 8 — expected stall=false (count would advance to 1, not 2)" "$out"
echo "$out" | grep -q 'next_head_sha_unchanged_count=1' \
  || fail "case 8 — expected next_head_sha_unchanged_count=1" "$out"
ok "case 8 — head-SHA counter advances to 1 without stalling"

# ── Case 9: SHA changed between iterations → counter resets to 0 ──────
cat > "$ROOT_TMP/pr-open-newsha.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": false, "headRefOid": "newshanew1234"}
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-newsha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 9 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 9 — expected stall=false (SHA changed)" "$out"
echo "$out" | grep -q 'next_head_sha_unchanged_count=0' \
  || fail "case 9 — expected next_head_sha_unchanged_count=0 (reset)" "$out"
ok "case 9 — SHA change resets counter"

# ── Case 10: Phase 1 — gh pr view fails with "not found" → terminal=true ─
out=$(GH_STUB_PR_VIEW_FAIL="could not resolve to a PullRequest" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 10 — handler should not error on not-found" "$out"
echo "$out" | grep -q 'terminal=true' \
  || fail "case 10 — expected terminal=true" "$out"
echo "$out" | grep -q 'reason=not-found' \
  || fail "case 10 — expected reason=not-found" "$out"
ok "case 10 — Phase 1 detects not-found terminal state"

# ── Case 11: Phase 1 — head branch deleted → terminal=true reason=branch-deleted ─
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_BRANCH_EXIT=22 \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 11 — handler should not error on branch-deleted" "$out"
echo "$out" | grep -q 'terminal=true' \
  || fail "case 11 — expected terminal=true" "$out"
echo "$out" | grep -q 'reason=branch-deleted' \
  || fail "case 11 — expected reason=branch-deleted" "$out"
ok "case 11 — Phase 1 detects branch-deleted terminal state"

# ── Case 12: head-SHA matches AND prior count=1 BUT CI pending → no stall ─
cat > "$ROOT_TMP/checks-pending.json" <<'JSON'
[{"name": "ci", "state": "IN_PROGRESS", "bucket": "pending"}]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-pending.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 12 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 12 — expected stall=false because CI is pending" "$out"
echo "$out" | grep -q 'reason=ci-pending' \
  || fail "case 12 — expected reason=ci-pending" "$out"
# Counter must NOT advance while stall is held back — otherwise two
# pending-CI iters followed by green would already trip the cap.
echo "$out" | grep -q 'next_head_sha_unchanged_count=1' \
  || fail "case 12 — counter should be preserved at prior value 1, not advanced to 2" "$out"
ok "case 12 — head-SHA stall held back while CI pending (counter preserved)"

# ── Case 13: head-SHA matches AND prior count=1 BUT new review activity → no stall ─
cat > "$ROOT_TMP/reviews-fresh.json" <<'JSON'
[{"user": {"login": "copilot[bot]"}, "submitted_at": "2026-05-28T13:00:00Z"}]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-fresh.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 13 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 13 — expected stall=false because new review activity" "$out"
echo "$out" | grep -q 'reason=new-review-activity' \
  || fail "case 13 — expected reason=new-review-activity" "$out"
echo "$out" | grep -q 'next_head_sha_unchanged_count=1' \
  || fail "case 13 — counter should be preserved at prior value 1" "$out"
ok "case 13 — head-SHA stall held back while reviewer activity is fresh (counter preserved)"

# ── Case 14: Phase 2 ci-action-required → stall=true ──────────────────
cat > "$ROOT_TMP/checks-action.json" <<'JSON'
[{"name": "deploy-gate", "state": "ACTION_REQUIRED", "bucket": "pending"}]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-action.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 14 — handler should not error" "$out"
echo "$out" | grep -q 'stall=true' \
  || fail "case 14 — expected stall=true" "$out"
echo "$out" | grep -q 'reason=ci-action-required' \
  || fail "case 14 — expected reason=ci-action-required" "$out"
ok "case 14 — CI action_required triggers stall"

# ── Case 15: Cross-repo PR (head in fork) → branch-deleted check skipped ─
cat > "$ROOT_TMP/pr-fork.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": false,
 "headRefOid": "deadbeef1234",
 "headRepository": {"name": "arboretum-dev-fork"},
 "headRepositoryOwner": {"login": "external-contributor"}}
JSON
# Stub branches API to return 404 — but the cross-repo guard should
# skip the lookup entirely, so terminal must still be false.
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-fork.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_BRANCH_EXIT=22 \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 15 — handler should not error on fork PR" "$out"
echo "$out" | grep -q 'terminal=false' \
  || fail "case 15 — cross-repo PR misdetected as branch-deleted" "$out"
ok "case 15 — cross-repo PR skips branch-deleted check"

# ── Case 16: branches API transient/rate-limit failure → NOT branch-deleted ─
# A failure with stderr that does NOT match 404 patterns must keep the
# PR in active state, not falsely declare branch-deleted (Codex round-3
# #3318640424). The gh stub here returns exit 22 with rate-limit-ish
# stderr; head_branch_exists should treat as uncertain → exists.
cat > "$ROOT_TMP/pr-same-repo.json" <<'JSON'
{"number": 999, "state": "OPEN", "headRefName": "feat/x", "isDraft": false,
 "headRefOid": "deadbeef1234",
 "headRepository": {"name": "arboretum-dev"},
 "headRepositoryOwner": {"login": "Stephen-van-Gaal"}}
JSON
# Build a one-off stub variant that emits a non-404 stderr on branches API.
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view")
    if [ -n "${GH_STUB_PR_VIEW_FAIL:-}" ]; then printf '%s\n' "$GH_STUB_PR_VIEW_FAIL" >&2; exit 1; fi
    cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*)
        printf 'API rate limit exceeded\n' >&2
        exit 22 ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks") cat "${GH_STUB_PR_CHECKS:-/dev/null}"; exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-same-repo.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 16 — handler should not error on transient branch lookup" "$out"
echo "$out" | grep -q 'terminal=false' \
  || fail "case 16 — non-404 branch lookup failure misclassified as deleted" "$out"
ok "case 16 — transient branches API failure treated as exists"

# ── Case 17: branches API returns confirmed 404 → branch-deleted ──────
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view")
    cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*)
        printf 'gh: Not Found (HTTP 404)\n' >&2
        exit 1 ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-same-repo.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      bash "$HELPERS" check-terminal 999 2>&1) \
  || fail "case 17 — handler should not error on confirmed 404" "$out"
echo "$out" | grep -q 'terminal=true' \
  || fail "case 17 — confirmed 404 should be terminal" "$out"
echo "$out" | grep -q 'reason=branch-deleted' \
  || fail "case 17 — expected reason=branch-deleted" "$out"
ok "case 17 — confirmed 404 detected as branch-deleted"

# ── Case 18: ACTION_REQUIRED with gh pr checks exit 8 (pending) ───────
# gh pr checks can exit non-zero (exit 8 for pending checks) while
# emitting valid JSON. Under pipefail, the prior implementation let
# `|| echo false` append after python's `true` output. Verify the
# fixed code reads ACTION_REQUIRED even when gh exits non-zero.
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view") cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks")
    cat "${GH_STUB_PR_CHECKS:-/dev/null}"
    # Simulate gh's documented "exit 8 when checks are pending" behavior
    # alongside valid JSON output.
    exit 8 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-action.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 18 — handler should not error" "$out"
echo "$out" | grep -q 'stall=true' \
  || fail "case 18 — ACTION_REQUIRED lost under pipefail when gh exits non-zero" "$out"
echo "$out" | grep -q 'reason=ci-action-required' \
  || fail "case 18 — expected reason=ci-action-required" "$out"
ok "case 18 — ACTION_REQUIRED detected even when gh pr checks exits non-zero"

# ── Case 19: stall guard sees line-comment activity (no review submission) ─
# Restore the standard stub before Case 19 (Cases 16-18 each rewrote it).
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view")
    if [ -n "${GH_STUB_PR_VIEW_FAIL:-}" ]; then printf '%s\n' "$GH_STUB_PR_VIEW_FAIL" >&2; exit 1; fi
    cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks") cat "${GH_STUB_PR_CHECKS:-/dev/null}"; exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"

# A reviewer posted only a line comment (Codex style) since the prior
# summary — no review submission. The stall guard must still detect
# fresh activity and suppress the head-SHA stall.
# Note: the stub serves the SAME fixture for both /comments and /reviews;
# we want comments to be fresh and reviews to be empty. Use
# GH_STUB_COMMENTS for the issue/PR comments fixture that read-journey-log
# sees (this is the issue-comments endpoint), and GH_STUB_API as a catch-all
# for the PR /comments endpoint that latest_review_activity_ts hits.
cat > "$ROOT_TMP/pr-line-comments-fresh.json" <<'JSON'
[{"id": 99, "user": {"login": "chatgpt-codex-connector[bot]"},
  "created_at": "2026-05-28T13:00:00Z",
  "updated_at": "2026-05-28T13:00:00Z",
  "path": "scripts/land-handler.sh", "line": 1, "body": "nit"}]
JSON
# Stub variant: PR /comments endpoint returns the fresh line comment;
# /reviews returns empty; issue /comments (for the journey log read)
# returns the prior summary fixture.
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view") cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/issues/"*"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/pulls/"*"/comments") cat "${GH_STUB_PR_LINE_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks") cat "${GH_STUB_PR_CHECKS:-/dev/null}"; exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_PR_LINE_COMMENTS="$ROOT_TMP/pr-line-comments-fresh.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 19 — handler should not error" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 19 — fresh line-comment activity not detected, stall fired" "$out"
echo "$out" | grep -q 'reason=new-review-activity' \
  || fail "case 19 — expected reason=new-review-activity" "$out"
ok "case 19 — fresh line-comment activity defers head-SHA stall"

# ── Case 20: gh pr checks completely fails → stall=unknown ────────────
# When the checks API is unreachable (gh exits non-zero with no JSON),
# check-stall must bail to stall=unknown so SKILL.md Phase 2 exits
# without scheduling a wake-up (Codex round-4 #3318835202). Previously
# this silently fell through to the head-SHA path with empty buckets,
# letting stall=true fire when CI state was actually unknown.
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view") cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks")
    printf 'gh: API rate limit exceeded\n' >&2
    exit 1 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-prior-count1.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 20 — handler should not error" "$out"
echo "$out" | grep -q 'stall=unknown' \
  || fail "case 20 — CI fetch failure should bail to stall=unknown" "$out"
echo "$out" | grep -q 'reason=ci-fetch-failed' \
  || fail "case 20 — expected reason=ci-fetch-failed" "$out"
ok "case 20 — gh pr checks failure → stall=unknown reason=ci-fetch-failed"

# ── Case 21: latest summary is a Phase 2 stall (no head_sha) → reset ──
# If the most recent /land summary is a Phase 2 stall (e.g. reason=draft),
# it has no head_sha key. check-stall must skip past Phase 2 summaries
# and find the most recent Phase 3 summary for head-SHA state, OR (if
# there is none) treat as no prior data and reset the counter to 0
# (Codex round-4 #3318835214). Restore the standard stub first.
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view") cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks") cat "${GH_STUB_PR_CHECKS:-/dev/null}"; exit 0 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"

# Fixture: latest summary is Phase 2 reason=draft (no head_sha), and
# there's an older Phase 3 summary with a different SHA. The Phase 3
# filter should pick the older Phase 3 row.
cat > "$ROOT_TMP/comments-phase2-then-phase3.json" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T10:00:00Z — /land summary, phase: 3, head_sha: cafebabe1234, head_sha_unchanged_count: 0"},
  {"id": 2, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T11:00:00Z — /land summary, phase: 2, stall: true, reason: draft"}
]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-phase2-then-phase3.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 21 — handler should not error on Phase 2 latest summary" "$out"
# Current SHA (deadbeef1234) differs from older Phase 3 (cafebabe1234)
# so the counter should reset to 0, not crash.
echo "$out" | grep -q 'stall=false' \
  || fail "case 21 — should not stall when latest summary lacks head_sha" "$out"
echo "$out" | grep -q 'next_head_sha_unchanged_count=0' \
  || fail "case 21 — counter should reset to 0 (SHA differs from older Phase 3)" "$out"
ok "case 21 — Phase 2 stall summaries are skipped when reading head-SHA state"

# ── Case 22: ONLY Phase 2 summaries exist → reset counter ─────────────
cat > "$ROOT_TMP/comments-phase2-only.json" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T11:00:00Z — /land summary, phase: 2, stall: true, reason: draft"}
]
JSON
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open-sha.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-phase2-only.json" \
      GH_STUB_PR_CHECKS="$ROOT_TMP/checks-green.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 22 — handler should not error on Phase-2-only history" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 22 — should not stall when no Phase 3 summary exists" "$out"
echo "$out" | grep -q 'next_head_sha_unchanged_count=0' \
  || fail "case 22 — counter should start at 0" "$out"
ok "case 22 — Phase-2-only history treated as no prior head-SHA data"

# ── Case 23: gh pr checks reports "no checks configured" → still works ─
# gh's "no checks reported on the '<branch>' branch" diagnostic is a
# documented no-CI-configured signal, not a true fetch failure. The
# original SKILL.md guarantees graceful degradation in this case
# (poll reviewers, skip CI). Round 4's ci-unknown sentinel must NOT
# fire here — that would break /land on every fresh-repo project
# (Codex round-5 #3319191443).
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "Stephen-van-Gaal/arboretum-dev"; exit 0 ;;
  "pr view") cat "${GH_STUB_PR_VIEW:-/dev/null}"; exit 0 ;;
  "api "*)
    case "$2" in
      *"/comments") cat "${GH_STUB_COMMENTS:-/dev/null}"; exit 0 ;;
      *"/branches/"*) exit "${GH_STUB_BRANCH_EXIT:-0}" ;;
      *"/reviews") cat "${GH_STUB_REVIEWS:-/dev/null}"; exit 0 ;;
      *) cat "${GH_STUB_API:-/dev/null}"; exit 0 ;;
    esac ;;
  "pr checks")
    printf "no checks reported on the 'feat/x' branch\n" >&2
    exit 1 ;;
  *) echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(GH_STUB_PR_VIEW="$ROOT_TMP/pr-open.json" \
      GH_STUB_COMMENTS="$ROOT_TMP/comments-empty.json" \
      GH_STUB_REVIEWS="$ROOT_TMP/reviews-empty.json" \
      bash "$HELPERS" check-stall 999 2>&1) \
  || fail "case 23 — handler should not error on no-checks-configured" "$out"
echo "$out" | grep -q 'stall=false' \
  || fail "case 23 — no-checks-configured must not trigger stall=unknown" "$out"
# Must NOT emit ci-fetch-failed (that's for real failures).
if echo "$out" | grep -q 'reason=ci-fetch-failed'; then
  fail "case 23 — no-CI-configured diagnostic misclassified as fetch failure" "$out"
fi
ok "case 23 — no checks configured falls through to head-SHA path (not stall=unknown)"

# ── Case 24: Phase 3 dispatches a read-only land driver ───────────────
grep -q 'allowed-tools:.*\bTask\b' "$LAND_SKILL" \
  || fail "case 24 — /land frontmatter does not allow the Task tool for driver dispatch"
grep -qi 'dispatch the land driver' "$LAND_SKILL" \
  || fail "case 24 — Phase 3 does not dispatch the land driver"
grep -qi 'general-purpose' "$LAND_SKILL" \
  || fail "case 24 — land driver is not a general-purpose subagent"
grep -qi 'work-product envelope' "$LAND_SKILL" \
  || fail "case 24 — driver report contract (work-product envelope) is undocumented"
grep -qi 'driver.*read-only\|read-only.*driver' "$LAND_SKILL" \
  || fail "case 24 — land driver is not declared read-only"
ok "case 24 — Phase 3 dispatches a read-only land driver"

# ── Case 25: mutations and the loop primitive stay in the conductor ───
grep -q 'ScheduleWakeup' "$LAND_SKILL" \
  || fail "case 25 — ScheduleWakeup callsite missing from the conductor"
grep -q 'review-closeout' "$LAND_SKILL" \
  || fail "case 25 — review-closeout no longer invoked by the conductor"
grep -qi 'merge handoff' "$LAND_SKILL" \
  || fail "case 25 — tiered merge handoff missing from the conductor"
grep -qi 'no mutating\|mutates no\|never mutates' "$LAND_SKILL" \
  || fail "case 25 — driver contract does not forbid mutation"
# Those mutations must NOT appear inside the driver-brief region. A bare
# string-existence check above would still pass if a regression moved a mutation
# into the driver's instructions, so assert absence within the brief block.
BRIEF=$(awk '/Driver brief \(conductor/{f=1} /driver.s three assess steps/{f=0} f' "$LAND_SKILL")
[ -n "$BRIEF" ] || fail "case 25 — could not locate the driver-brief region (heading drift?)"
for tok in 'ScheduleWakeup' 'review-closeout' 'merge handoff'; do
  if printf '%s\n' "$BRIEF" | grep -qi "$tok"; then
    fail "case 25 — '$tok' appears inside the driver brief (must stay conductor-side)"
  fi
done
ok "case 25 — mutations + ScheduleWakeup conductor-side and absent from the driver brief"

# ── Case 26: Phases 1 and 2 never dispatch a driver ───────────────────
# Extract the text from "### Phase 1" up to (not including) "### Phase 3"
# and assert it contains no land-driver dispatch — a terminal or stalled
# PR must never spawn a subagent.
PHASE12=$(awk '/^### Phase 1: Terminal check/{f=1} /^### Phase 3: Active iteration/{f=0} f' "$LAND_SKILL")
# Guard against a vacuous pass: a renamed heading makes the range empty, and the
# grep below would then find nothing and falsely pass. Require a non-empty extract.
[ -n "$PHASE12" ] || fail "case 26 — Phase 1/2 region extraction empty (heading drift?) — would vacuously pass"
if printf '%s\n' "$PHASE12" | grep -qi 'dispatch the land driver'; then
  fail "case 26 — Phase 1/2 dispatches a driver (must only happen in Phase 3)"
fi
ok "case 26 — Phases 1 and 2 do not dispatch a driver"

# ── Case 27: Phase 3 Step 4 dispatches a fixer driver after the triage gate ──
# The fix sub-loop delegates fix *composition* to a fresh-context fixer driver.
grep -qi 'fixer driver' "$LAND_SKILL" \
  || fail "case 27 — Step 4 does not dispatch a fixer driver"
# The triage 'say stop' notification must appear BEFORE the fixer dispatch.
TRIAGE_LINE=$(grep -n "say 'stop'\|say \"stop\"\|Say 'stop'\|Say \"stop\"" "$LAND_SKILL" | head -1 | cut -d: -f1)
# Anchor on the dispatch *directive*, not the first generic "fixer driver"
# mention (which is the intro paragraph and would make this ordering check pass
# vacuously even if the dispatch moved ahead of the triage gate).
FIXER_LINE=$(grep -ni 'dispatch the fixer driver' "$LAND_SKILL" | head -1 | cut -d: -f1)
[ -n "$TRIAGE_LINE" ] || fail "case 27 — triage 'say stop' notification missing (heading drift?)"
[ -n "$FIXER_LINE" ]  || fail "case 27 — fixer-driver dispatch directive not found"
[ "$TRIAGE_LINE" -lt "$FIXER_LINE" ] \
  || fail "case 27 — fixer driver is dispatched before the human triage gate (must be after)"
ok "case 27 — Phase 3 Step 4 dispatches a fixer driver after the triage gate"

# ── Case 28: the fixer composes + commits LOCAL only; brief forbids remote work ──
# The fixer must commit locally and NOT push / consolidate / close out.
grep -qi 'commit.*local\|local.*commit\|commits locally' "$LAND_SKILL" \
  || fail "case 28 — fixer is not declared to commit locally only"
# Positively assert the no-remote-mutation boundary statement EXISTS — the
# load-bearing control. Without this, a future edit could delete the boundary
# prose and the absence-of-forbidden-tokens checks below would still pass green.
grep -qi 'forbidden to push' "$LAND_SKILL" \
  || fail "case 28 — fixer no-push boundary statement missing"
# Locate the fixer-region and assert the forbidden tokens are ABSENT from it
# (mirrors case 25's awk-region technique for the assess driver). End-anchor on
# the "Conductor: verify HEAD" heading ONLY — the earlier "[Cc]onductor reconcile"
# substring matched inside the brief and truncated the region BEFORE the fixer's
# action steps (the `git commit` block), the highest-risk surface for an
# accidental remote-mutation instruction. The wider region now covers it.
FIXER_BRIEF=$(awk '/[Ff]ixer brief \(conductor/{f=1} /[Cc]onductor: verif|^### 5\. Review closeout/{f=0} f' "$LAND_SKILL")
[ -n "$FIXER_BRIEF" ] || fail "case 28 — could not locate the fixer-brief region (heading drift?)"
for tok in 'git push' '/consolidate' 'review-closeout'; do
  if printf '%s\n' "$FIXER_BRIEF" | grep -qiF "$tok"; then
    fail "case 28 — '$tok' appears inside the fixer brief (must stay conductor-side)"
  fi
done
ok "case 28 — fixer commits local only; brief forbids push/consolidate/closeout"

# ── Case 29: HEAD reconciliation, push, fixes.json, cap + ScheduleWakeup conductor-side ──
# The conductor verifies the returned SHA against local HEAD before pushing.
grep -qi 'rev-parse HEAD' "$LAND_SKILL" \
  || fail "case 29 — conductor does not verify git rev-parse HEAD against the returned SHA"
grep -qi 'head_sha_after' "$LAND_SKILL" \
  || fail "case 29 — envelope field head_sha_after not documented"
# fixes.json is written conductor-side, after the push.
grep -q 'fixes.json' "$LAND_SKILL" \
  || fail "case 29 — fixes.json write missing from the conductor"
# The 2-round cap and ScheduleWakeup remain conductor-side (not in the fixer brief).
grep -qi '2.*round\|two.*round\|cap: 2' "$LAND_SKILL" \
  || fail "case 29 — 2-round cap missing from the conductor"
if [ -n "$FIXER_BRIEF" ]; then
  for tok in 'ScheduleWakeup' 'cap: 2'; do
    if printf '%s\n' "$FIXER_BRIEF" | grep -qiF "$tok"; then
      fail "case 29 — '$tok' appears inside the fixer brief (must stay conductor-side)"
    fi
  done
fi
ok "case 29 — HEAD reconciliation + push + fixes.json + cap + ScheduleWakeup conductor-side"

# ── Case 30: the conductor VERIFIES the fixer's work before pushing ──
# The brief's no-push/no-consolidate/no-closeout prohibitions are instruction-
# level only (a general-purpose subagent carries write tools). The conductor's
# pre-push verification is the capability-level backstop (decision D59), hardened
# per B4 + Codex review — pin each check so a future edit cannot silently drop it.
# Baselines captured BEFORE dispatch (Copilot 3482475866): the checks key off
# base_local + base_remote, so the prose must say to record them up front.
grep -qi 'base_local' "$LAND_SKILL" \
  || fail "case 30 — base_local baseline (rev-parse HEAD before dispatch) not captured"
grep -qi 'base_remote' "$LAND_SKILL" \
  || fail "case 30 — base_remote baseline (origin/<branch> before dispatch) not captured"
grep -qi 'no-op check' "$LAND_SKILL" \
  || fail "case 30 — conductor no-op check (HEAD == base_local ⇒ push nothing) missing"
grep -qi 'push nothing\|composed nothing' "$LAND_SKILL" \
  || fail "case 30 — no-op path does not state the conductor pushes nothing"
# Dirty-tree no-op guard (Codex P2 3482500843): a crashed fixer leaves dirty edits.
grep -qi 'git status --porcelain\|dirty' "$LAND_SKILL" \
  || fail "case 30 — no-op path does not require a clean worktree (dirty ⇒ reset)"
# Reset unverified/mismatched commits (Codex P1 3482500847): no stacking.
grep -qi 'git reset --hard base_local\|reset --hard .base_local' "$LAND_SKILL" \
  || fail "case 30 — mismatch/dirty path does not reset to base_local before re-dispatch"
# Exactly one commit (Codex P2 3482500853).
grep -qi 'rev-list --count base_local..HEAD\|exactly one commit\|exactly .*one.* commit' "$LAND_SKILL" \
  || fail "case 30 — conductor does not verify exactly one commit base_local..HEAD"
# Rogue-push guard with a fetch (Codex P2 3482500851/3482500853).
grep -qi 'rogue-push\|rogue fixer push\|out of band' "$LAND_SKILL" \
  || fail "case 30 — conductor rogue-push check (remote head moved out of band) missing"
grep -qi 'git fetch origin' "$LAND_SKILL" \
  || fail "case 30 — rogue-push check does not fetch before comparing origin/<branch>"
# Scope check recomputes from git, does not trust files_touched (Codex P1 3482500839).
grep -qi 'git diff --name-only base_local..HEAD' "$LAND_SKILL" \
  || fail "case 30 — scope check does not recompute touched paths from the commit"
grep -qi 'within the scope\|out-of-scope\|allowed scope' "$LAND_SKILL" \
  || fail "case 30 — scope check does not constrain touched paths to the addressed clusters"
# CI-fix files allowed through scope (Codex P2 3482500835).
grep -qi 'CI.fix\|CI-failure fix\|CI-only round\|CI failure' "$LAND_SKILL" \
  || fail "case 30 — scope check does not allow CI-fix files through"
grep -qi 'capability.*backstop' "$LAND_SKILL" \
  || fail "case 30 — conductor verification is not framed as the capability backstop"
# Round-2 hardening (Codex re-review): pin the second-order checks.
# Clean-tree precondition before dispatch (3482703754).
grep -qi 'clean-tree precondition\|porcelain` must be empty before' "$LAND_SKILL" \
  || fail "case 30 — no clean-tree precondition before capturing base_local/dispatch"
# Untracked cleanup on dirty no-op (3482703714): reset --hard alone leaves untracked.
grep -qi 'git clean -fd' "$LAND_SKILL" \
  || fail "case 30 — dirty no-op path does not git clean -fd untracked files"
# Clean-tree gate before push (3482703721).
grep -qi 'clean-tree gate' "$LAND_SKILL" \
  || fail "case 30 — no clean-tree gate before push (stray edits could contaminate)"
# fixes.json keyed to the conductor's verified pushed commit, not fixer-reported (3482703701).
grep -qi "verified pushed commit\|conductor's own verified" "$LAND_SKILL" \
  || fail "case 30 — fixes.json not derived from the conductor's verified pushed commit"
# Reconcile decision from git-computed paths, not files_touched (3482703748).
grep -qi 'reconcile decision from git\|git-computed.* touched' "$LAND_SKILL" \
  || fail "case 30 — /consolidate reconcile decision not derived from git-computed paths"
# Empty fixes ledger on a clean no-op that still closes out (3482703739).
grep -q '"items":\[\]' "$LAND_SKILL" \
  || fail "case 30 — clean no-op with replies does not write an empty review-fixes ledger"
# Top-level (non-inline) fix comments get a real scope, not an empty one (3482703728).
grep -qi 'top-level / conversation comments\|top-level.*conversation comment' "$LAND_SKILL" \
  || fail "case 30 — scope check gives top-level/non-inline fixes an empty scope"
ok "case 30 — conductor verifies fixer work (baselines + clean precondition/gate + no-op/dirty+clean -fd + reconcile/reset + one-commit + fetch/rogue + recomputed+top-level scope + verified-commit ledger + git reconcile) before pushing"

echo "ALL PASS"
