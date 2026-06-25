#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# land-handler.sh — Bash helpers backing /land's three-phase handler.
# Subcommands:
#   check-terminal <pr-number>   → Phase 1 terminal-state check
#   check-stall <pr-number>      → Phase 2 stall-state check
#
# Output: KEY=VALUE pairs on stdout. Never prints to stderr unless
# fatally erroring. NEVER calls ScheduleWakeup — that gate belongs to
# /land's Phase 3 prose.
#
# Environment:
#   ISSUE — pipeline-state issue number used for journey-log reads/writes.
#           Defaults to <pr-number> when unset, so reads and writes stay
#           aligned when /land runs standalone (without /finish chaining
#           in a separate $ISSUE).
#
# See docs/superpowers/specs/2026-05-28-land-loop-termination-design.md.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "land-handler.sh requires bash" >&2; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  check-terminal) ;;
  check-stall) ;;
  *) echo "Usage: land-handler.sh {check-terminal|check-stall} <pr-number>" >&2; exit 1 ;;
esac

PR="${1:?pr-number required}"
# Journey-log reads/writes are per-$ISSUE (per WS9 state-tracking design).
# Default ISSUE to PR so a standalone /land run reads/writes its own thread
# without requiring the caller to set ISSUE explicitly.
LAND_ISSUE="${ISSUE:-$PR}"

command -v gh >/dev/null 2>&1 || { echo "land-handler.sh requires the gh CLI" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/read-journey-log.sh"

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")

# Fetch PR state with one retry on transient failure.
# Distinguishes "not found" from transient failures (rate limit, network).
# Returns:
#   0 + JSON on stdout → success
#   2 + nothing       → not-found (do not retry; caller treats as terminal)
#   1 + nothing       → transient failure (caller treats as fetch-failed)
# Tests can short-circuit the retry sleep by setting FETCH_RETRY_SLEEP=0.
fetch_pr_view() {
  local stderr_file out rc=""
  stderr_file=$(mktemp)
  out=$(gh pr view "$PR" --json number,state,headRefName,isDraft,headRefOid,headRepository,headRepositoryOwner 2>"$stderr_file") || rc=$?
  if [ -z "$rc" ]; then
    printf '%s' "$out"
    rm -f "$stderr_file"
    return 0
  fi
  if grep -qiE 'no pull request|could not resolve|not found' "$stderr_file" 2>/dev/null; then
    rm -f "$stderr_file"
    return 2
  fi
  sleep "${FETCH_RETRY_SLEEP:-10}"
  rc=""
  out=$(gh pr view "$PR" --json number,state,headRefName,isDraft,headRefOid,headRepository,headRepositoryOwner 2>"$stderr_file") || rc=$?
  if [ -z "$rc" ]; then
    printf '%s' "$out"
    rm -f "$stderr_file"
    return 0
  fi
  if grep -qiE 'no pull request|could not resolve|not found' "$stderr_file" 2>/dev/null; then
    rm -f "$stderr_file"
    return 2
  fi
  rm -f "$stderr_file"
  return 1
}

# Detect warm-vs-cold entry: presence of any prior /land summary entry.
detect_entry_mode() {
  local rows
  if rows=$(bash "$READER" "$LAND_ISSUE" --stage /land --action summary 2>/dev/null); then
    if [ -n "$rows" ]; then echo "warm"; return 0; fi
  fi
  echo "cold"
}

# Check whether the PR's head branch still exists on the remote.
# Returns 0 (exists or unknown) or 1 (confirmed deleted via HTTP 404).
# On any uncertainty (no REPO, missing branch name, cross-repo PR
# whose head lives in a fork, transient/auth/rate-limit failures)
# treats as "exists" to avoid false-positive terminal exit.
#
# Args: $1=head_ref  $2=head_repo (nameWithOwner from gh pr view)
# For PRs opened from a fork, head_repo != REPO. In that case we'd need
# to query the fork's branches endpoint; the safer default for now is
# to skip the check (Codex round-2 review #3318312218).
# Only a confirmed 404 from the branches API counts as deleted; other
# gh api failures (rate limit, auth, network) leave us uncertain and
# must NOT trigger terminal=branch-deleted (Codex round-3 #3318640424).
head_branch_exists() {
  local head_ref="$1" head_repo="$2" stderr_file rc=""
  [ -z "$REPO" ] && return 0
  [ -z "$head_ref" ] && return 0
  if [ -n "$head_repo" ] && [ "$head_repo" != "$REPO" ]; then
    return 0
  fi
  stderr_file=$(mktemp)
  gh api "repos/$REPO/branches/$head_ref" >/dev/null 2>"$stderr_file" || rc=$?
  if [ -z "$rc" ]; then
    rm -f "$stderr_file"
    return 0
  fi
  # Confirm 404 via stderr classification; anything else stays "exists".
  if grep -qiE 'HTTP 404|Not Found|branch not found' "$stderr_file"; then
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  return 0
}

# Capture `gh pr checks --json ...` output as a string. Critical that
# we DO NOT pipe gh's output through python directly: gh exits non-zero
# when checks are pending (documented exit code 8) while still emitting
# valid JSON. Under `set -o pipefail`, a piped form would let the
# fallback overwrite python's correct output (Codex round-3 #3318640429).
#
# Also distinguishes "no checks reported" (no CI configured on the
# branch — exit non-zero with a stderr diagnostic and no JSON) from a
# real fetch failure (network/auth/rate-limit). The original SKILL.md
# "Graceful degradation: no CI configured -> skip the CI signal, still
# poll reviewers" guarantee must hold (Codex round-5 #3319191443).
#
# Returns:
#   - valid JSON (possibly "[]") on success or no-checks-configured
#   - empty string on a real fetch failure
_fetch_pr_checks() {
  local stderr_file out
  stderr_file=$(mktemp)
  # Don't gate on the exit code: gh exits 8 when checks are pending
  # while still emitting valid JSON; rejecting non-zero exits would
  # discard correct ACTION_REQUIRED detection in that case.
  out=$(gh pr checks "$PR" --json state,bucket,name 2>"$stderr_file") || true
  if [ -n "$out" ]; then
    rm -f "$stderr_file"
    printf '%s' "$out"
    return 0
  fi
  # Empty stdout: distinguish "no checks configured" (documented
  # stderr diagnostic; legitimately zero checks) from a true fetch
  # failure (network/auth/rate-limit; caller must treat as unknown).
  if grep -qiE 'no checks reported|no checks for' "$stderr_file" 2>/dev/null; then
    rm -f "$stderr_file"
    echo "[]"
    return 0
  fi
  rm -f "$stderr_file"
  return 0
}

# Read CI bucket distribution: returns space-separated unique buckets.
# Emits the sentinel "__unknown__" when the checks API fetch fails so
# callers can distinguish "no buckets / no checks configured" (which is
# safe to treat as non-pending) from "fetch failed" (which is NOT —
# CI could be in any state and a stall decision is unsafe). Codex
# round-4 #3318835202.
ci_buckets() {
  local checks_json
  checks_json=$(_fetch_pr_checks)
  if [ -z "$checks_json" ]; then
    echo "__unknown__"
    return 0
  fi
  printf '%s' "$checks_json" | python3 -c '
import json, sys
try:
  data = json.load(sys.stdin)
  buckets = sorted({(c.get("bucket") or "").lower() for c in data if c.get("bucket")})
  print(" ".join(buckets))
except Exception:
  print("__unknown__")
'
}

# Detect a check in ACTION_REQUIRED state. Returns "true"/"false"/"unknown".
# "unknown" means the checks API was unreachable — callers must NOT
# treat that as "false" (otherwise ACTION_REQUIRED present in the real
# state would be silently missed). Same Codex round-4 concern.
ci_action_required() {
  local checks_json
  checks_json=$(_fetch_pr_checks)
  if [ -z "$checks_json" ]; then
    echo "unknown"
    return
  fi
  printf '%s' "$checks_json" | python3 -c '
import json, sys
try:
  data = json.load(sys.stdin)
  for c in data:
    if (c.get("state") or "").upper() == "ACTION_REQUIRED":
      print("true"); break
  else:
    print("false")
except Exception:
  print("unknown")
'
}

# Get the timestamp of the most recent reviewer activity — both review
# submissions (/pulls/{N}/reviews use `submitted_at`) AND line comments
# (/pulls/{N}/comments use `created_at`/`updated_at`). Some reviewers
# (Codex notably) post line comments without ever submitting a review
# wrapper, so a reviews-only check would silently miss fresh feedback
# and let Phase 2 stall while unread comments sit on the PR (Codex
# round-3 #3318640433).
#
# Empty if no activity or fetch fails. Consumes paginated concatenated
# JSON via raw_decode (Codex round-2 #3318312228).
latest_review_activity_ts() {
  [ -z "$REPO" ] && return 0
  {
    gh api "repos/$REPO/pulls/$PR/reviews" --paginate 2>/dev/null
    gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null
  } | python3 -c '
import json, sys
try:
  text = sys.stdin.read().lstrip()
  dec = json.JSONDecoder()
  items = []
  pos, n = 0, len(text)
  while pos < n:
    while pos < n and text[pos].isspace():
      pos += 1
    if pos >= n:
      break
    obj, end = dec.raw_decode(text, pos)
    if isinstance(obj, list):
      items.extend(obj)
    else:
      items.append(obj)
    pos = end
  ts = []
  for it in items:
    if it.get("submitted_at"):
      ts.append(it["submitted_at"])
    if it.get("created_at"):
      ts.append(it["created_at"])
    if it.get("updated_at"):
      ts.append(it["updated_at"])
  if ts:
    print(max(ts))
except Exception:
  pass
' || true
}

case "$cmd" in
  check-terminal)
    pr_json=""
    fetch_rc=0
    pr_json=$(fetch_pr_view) || fetch_rc=$?
    if [ "$fetch_rc" -eq 2 ]; then
      entry=$(detect_entry_mode)
      echo "terminal=true reason=not-found entry=$entry"
      exit 0
    fi
    if [ "$fetch_rc" -ne 0 ]; then
      echo "terminal=unknown reason=fetch-failed"
      exit 0
    fi
    state=$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
    head_ref=$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("headRefName",""))')
    # headRepository can be null (deleted fork) or a {name: ...} object;
    # headRepositoryOwner is similarly {login: ...} or null. When both
    # are present, build nameWithOwner for the fork-aware branch check.
    head_repo=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  hr = d.get("headRepository") or {}
  ho = d.get("headRepositoryOwner") or {}
  name = hr.get("name", "")
  owner = ho.get("login", "")
  print(f"{owner}/{name}" if owner and name else "")
except Exception: print("")
')
    entry=$(detect_entry_mode)
    case "$state" in
      MERGED) echo "terminal=true reason=merged entry=$entry" ;;
      CLOSED) echo "terminal=true reason=closed entry=$entry" ;;
      OPEN)
        if ! head_branch_exists "$head_ref" "$head_repo"; then
          echo "terminal=true reason=branch-deleted entry=$entry"
        else
          echo "terminal=false entry=$entry"
        fi
        ;;
      *)      echo "terminal=unknown reason=unexpected-state:$state entry=$entry" ;;
    esac
    ;;
  check-stall)
    pr_json=""
    fetch_rc=0
    pr_json=$(fetch_pr_view) || fetch_rc=$?
    if [ "$fetch_rc" -ne 0 ]; then
      echo "stall=unknown reason=fetch-failed"
      exit 0
    fi
    is_draft=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try: d = json.load(sys.stdin); print("true" if d.get("isDraft") else "false")
except Exception: print("false")
')
    if [ "$is_draft" = "true" ]; then
      echo "stall=true reason=draft"
      exit 0
    fi
    # CI action_required check (uses correct gh pr checks --json fields).
    ar=$(ci_action_required)
    if [ "$ar" = "true" ]; then
      echo "stall=true reason=ci-action-required"
      exit 0
    fi
    # If we can't read CI status at all, no CI-dependent stall decision
    # is safe. Bail to stall=unknown so SKILL.md Phase 2 exits without
    # scheduling (per design spec § Error handling). Codex round-4
    # #3318835202.
    if [ "$ar" = "unknown" ]; then
      echo "stall=unknown reason=ci-fetch-failed"
      exit 0
    fi
    # Head-SHA-unchanged stall check.
    current_sha=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try: d = json.load(sys.stdin); print(d.get("headRefOid", ""))
except Exception: print("")
')
    if [ -z "$current_sha" ]; then
      echo "stall=false reason=head-sha-unreadable"
      exit 0
    fi
    # Read most recent prior /land summary entry from $LAND_ISSUE that
    # carries head-SHA state. Phase 2 stall summaries (reason=draft,
    # reason=ci-action-required, etc.) do not include head_sha, so a
    # blind `--latest` could pick a row with no SHA data and corrupt
    # counter tracking. Filter to Phase 3 rows (which carry head_sha)
    # and pick the most recent (Codex round-4 #3318835214).
    all_summaries=$(bash "$READER" "$LAND_ISSUE" --stage /land --action summary 2>/dev/null || true)
    # Match phase=3 anchored on tab or line boundary so head_sha_unchanged_count=3 etc. don't false-positive.
    prior_row=$(printf '%s\n' "$all_summaries" | grep -E $'(^|\t)phase=3(\t|$)' | tail -1 || true)
    if [ -z "$prior_row" ]; then
      echo "stall=false next_head_sha_unchanged_count=0 current_head_sha=$current_sha"
      exit 0
    fi
    prior_sha=$(printf '%s\n' "$prior_row" | tr '\t' '\n' | grep -E '^head_sha=' | head -1 | cut -d= -f2-)
    prior_count=$(printf '%s\n' "$prior_row" | tr '\t' '\n' | grep -E '^head_sha_unchanged_count=' | head -1 | cut -d= -f2-)
    prior_ts=$(printf '%s\n' "$prior_row" | awk -F'\t' '{print $1}')
    prior_count="${prior_count:-0}"
    if [ "$current_sha" = "$prior_sha" ]; then
      next_count=$(( prior_count + 1 ))
      # Only stall if (count would reach >=2) AND CI is not pending
      # AND no new review activity since the prior summary. A long-
      # running CI or fresh reviewer activity is real progress even
      # when the head SHA hasn't moved, and shouldn't trip the cap.
      if [ "$next_count" -ge 2 ]; then
        buckets=$(ci_buckets)
        # Belt-and-braces: ci_action_required's "unknown" path above
        # already exits with stall=unknown when the checks fetch fails.
        # If a transient slipped through, treat "__unknown__" the same.
        case " $buckets " in
          *"__unknown__"*)
            echo "stall=unknown reason=ci-fetch-failed"
            exit 0
            ;;
        esac
        ci_pending="false"
        case " $buckets " in
          *" pending "*) ci_pending="true" ;;
        esac
        review_ts=$(latest_review_activity_ts)
        new_review_activity="false"
        if [ -n "$review_ts" ] && [ -n "$prior_ts" ]; then
          # String comparison on ISO 8601 timestamps is correct.
          if [ "$review_ts" \> "$prior_ts" ]; then
            new_review_activity="true"
          fi
        fi
        # When stall is suppressed by pending CI or fresh review activity,
        # do NOT advance the persisted counter. If we did, two pending-CI
        # iterations followed by a green check would already start at
        # count=2 and stall in Phase 2 before Phase 3 can observe the
        # green checks and hand off (Codex round-2 review #3318312224).
        if [ "$ci_pending" = "true" ]; then
          echo "stall=false next_head_sha_unchanged_count=$prior_count current_head_sha=$current_sha reason=ci-pending"
          exit 0
        fi
        if [ "$new_review_activity" = "true" ]; then
          echo "stall=false next_head_sha_unchanged_count=$prior_count current_head_sha=$current_sha reason=new-review-activity"
          exit 0
        fi
        echo "stall=true reason=head-sha-unchanged head_sha_unchanged_count=$next_count current_head_sha=$current_sha"
        exit 0
      fi
      echo "stall=false next_head_sha_unchanged_count=$next_count current_head_sha=$current_sha"
    else
      echo "stall=false next_head_sha_unchanged_count=0 current_head_sha=$current_sha"
    fi
    ;;
esac
