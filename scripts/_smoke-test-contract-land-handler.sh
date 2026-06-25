#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-land-handler.sh — Contract test for
# docs/contracts/land-handler.contract.md. Asserts LH-1..LH-8 against
# scripts/land-handler.sh.
#
# land-handler.sh shells out to `gh` (repo view, pr view, pr checks,
# api .../reviews|comments|branches) and invokes read-journey-log.sh
# (which itself calls `gh repo view` + `gh api .../comments`). We shadow
# PATH with a `gh` stub driven by env vars so the whole chain runs
# deterministically with no network:
#   GH_PR_JSON      → payload for `gh pr view ... --json ...`
#   GH_PR_VIEW_RC   → exit code + stderr keyword for the pr-view path
#   GH_CHECKS_JSON  → payload for `gh pr checks ... --json ...`
# `gh repo view`, `gh api .../comments` (journey log), branches, reviews
# all return benign empties so the read-journey-log dependency is happy.
# FETCH_RETRY_SLEEP=0 short-circuits the pr-view retry sleep.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/land-handler.sh"
LAND_SKILL="$SCRIPT_DIR/../skills/land/SKILL.md"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }
[ -f "$LAND_SKILL" ] || { echo "FAIL: $LAND_SKILL not found" >&2; exit 1; }

GH_STUB_DIR=$(mktemp -d)
trap 'rm -rf "$GH_STUB_DIR" "${NOGH_BIN:-}"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# ── gh stub ──────────────────────────────────────────────────────────
# Single stub driven by env vars. Defaults: branch exists (api branches
# exits 0), journey-log/reviews/comments empty, pr view returns GH_PR_JSON.
#   GH_PR_VIEW_RC / GH_PR_VIEW_STDERR → simulate a pr-view failure
#   GH_BRANCH_RC                      → simulate a deleted branch (404)
cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  repo)  printf 'foo/bar\n'; exit 0 ;;            # repo view --json nameWithOwner
  pr)
    case "$2" in
      view)
        if [ -n "${GH_PR_VIEW_RC:-}" ] && [ "${GH_PR_VIEW_RC}" != 0 ]; then
          echo "${GH_PR_VIEW_STDERR:-no pull request found}" >&2
          exit "${GH_PR_VIEW_RC}"
        fi
        printf '%s' "${GH_PR_JSON:-EMPTY}"
        exit 0 ;;
      checks)
        printf '%s' "${GH_CHECKS_JSON:-[]}"
        exit 0 ;;
    esac ;;
  api)
    case "$*" in
      *branches*)
        if [ "${GH_BRANCH_RC:-0}" != 0 ]; then echo "HTTP 404: Not Found" >&2; exit 1; fi
        exit 0 ;;                       # branch exists (HTTP 200)
      *) printf '[]'; exit 0 ;;         # journey-log comments / reviews / comments
    esac ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$GH_STUB_DIR/gh"

run() { PATH="$GH_STUB_DIR:$PATH" FETCH_RETRY_SLEEP=0 bash "$PROBE" "$@" 2>"$GH_STUB_DIR/.err"; }

# LH-1 — MERGED PR → terminal=true reason=merged
out=$(GH_PR_JSON='{"number":42,"state":"MERGED","headRefName":"feat/x","isDraft":false,"headRefOid":"sha1","headRepository":{"name":"bar"},"headRepositoryOwner":{"login":"foo"}}' run check-terminal 42); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == terminal=true\ reason=merged\ entry=* ]]; then pass LH-1
else fail_case LH-1 "rc=$rc out=$out err=$(cat "$GH_STUB_DIR/.err")"; fi

# LH-2 — OPEN PR, head branch exists (api branches → 200) → terminal=false
out=$(GH_PR_JSON='{"number":42,"state":"OPEN","headRefName":"feat/x","isDraft":false,"headRefOid":"sha1","headRepository":{"name":"bar"},"headRepositoryOwner":{"login":"foo"}}' run check-terminal 42); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == terminal=false\ entry=* ]]; then pass LH-2
else fail_case LH-2 "rc=$rc out=$out err=$(cat "$GH_STUB_DIR/.err")"; fi

# LH-3 — not-found PR → terminal=true reason=not-found (no retry stall)
out=$(GH_PR_VIEW_RC=1 GH_PR_VIEW_STDERR='no pull request found for branch' run check-terminal 42); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == terminal=true\ reason=not-found\ entry=* ]]; then pass LH-3
else fail_case LH-3 "rc=$rc out=$out err=$(cat "$GH_STUB_DIR/.err")"; fi

# LH-4 — draft PR → stall=true reason=draft
out=$(GH_PR_JSON='{"number":42,"state":"OPEN","headRefName":"feat/x","isDraft":true,"headRefOid":"sha1"}' run check-stall 42); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "stall=true reason=draft" ]; then pass LH-4
else fail_case LH-4 "rc=$rc out=$out err=$(cat "$GH_STUB_DIR/.err")"; fi

# LH-5 — ready PR, green CI ([] checks → no buckets, not action-required),
# no prior Phase-3 summary (journey log empty) → stall=false count=0
out=$(GH_PR_JSON='{"number":42,"state":"OPEN","headRefName":"feat/x","isDraft":false,"headRefOid":"deadbeef"}' GH_CHECKS_JSON='[]' run check-stall 42); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == stall=false\ next_head_sha_unchanged_count=0\ current_head_sha=deadbeef* ]]; then pass LH-5
else fail_case LH-5 "rc=$rc out=$out err=$(cat "$GH_STUB_DIR/.err")"; fi

# LH-6 — invocation errors
out=$(PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && pass "LH-6 (no subcommand)" || fail_case "LH-6 (no subcommand)" "rc=$rc out=$out"
out=$(PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" check-terminal 2>/dev/null); rc=$?
[ "$rc" = 1 ] && pass "LH-6 (no pr-number)" || fail_case "LH-6 (no pr-number)" "rc=$rc out=$out"

# LH-7 — gh absent → exit 1. Shadow PATH with only core tools, no gh.
NOGH_BIN=$(mktemp -d)
for t in python3 mktemp date cat rm bash sed grep awk dirname cd; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOGH_BIN/$t" 2>/dev/null || true
done
out=$(PATH="$NOGH_BIN" bash "$PROBE" check-terminal 42 2>/dev/null); rc=$?
[ "$rc" = 1 ] && pass LH-7 || fail_case LH-7 "rc=$rc out=$out"

# LH-8 — /land routes Azure DevOps away from this GitHub-only helper.
if grep -q 'LAND_BACKEND' "$LAND_SKILL" \
   && grep -q 'azure-devops' "$LAND_SKILL" \
   && grep -q 'Do not call `gh pr view`' "$LAND_SKILL" \
   && grep -q 'skip the GitHub handler' "$LAND_SKILL"; then
  pass LH-8
else
  fail_case LH-8 "skills/land/SKILL.md no longer documents the Azure DevOps bypass of land-handler.sh"
fi

[ "$fail" = 0 ] && echo "land-handler contract: ALL PASS" || exit 1
