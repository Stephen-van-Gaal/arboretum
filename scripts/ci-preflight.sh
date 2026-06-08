#!/usr/bin/env bash
# owner: git-workflow-tooling
# ci-preflight.sh — cheap blocker gate before expensive CI.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY_SAFE_REPAIRS=0
CONTINUE_AFTER_REPAIR=0
SCOPE="standard"
REPAIR_COMMIT_MODE="none"
REPAIR_BRANCH="${CI_PREFLIGHT_REPAIR_BRANCH:-}"
PUSH_SAFE_REPAIRS=0
GH_CMD="${CI_PREFLIGHT_GH:-gh}"
BOT_AUTHOR="${CI_PREFLIGHT_BOT_AUTHOR:-github-actions[bot]}"
BOT_EMAIL="${CI_PREFLIGHT_BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
COMMIT_MESSAGE="${CI_PREFLIGHT_COMMIT_MESSAGE:-chore: repair CI preflight blockers}"
REPAIR_PR_TITLE="${CI_PREFLIGHT_REPAIR_PR_TITLE:-Repair CI preflight blockers}"
REPAIR_PR_MARKER="<!-- arboretum-ci-preflight-repair:bot-owned -->"
repair_applied=0
repair_branch_prepared=0
declare -a blockers=()

usage() {
  echo "usage: ci-preflight.sh [--apply-safe-repairs] [--scope standard|release] [--continue-after-repair] [--repair-commit-mode none|same-branch|repair-pr] [--repair-branch <branch>] [--push-safe-repairs] [--gh-cmd <cmd>] [--root <path>]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply-safe-repairs)
      APPLY_SAFE_REPAIRS=1
      shift
      ;;
    --continue-after-repair)
      CONTINUE_AFTER_REPAIR=1
      shift
      ;;
    --scope)
      [ $# -ge 2 ] || { usage; exit 2; }
      SCOPE="$2"
      shift 2
      ;;
    --repair-commit-mode)
      [ $# -ge 2 ] || { usage; exit 2; }
      REPAIR_COMMIT_MODE="$2"
      shift 2
      ;;
    --repair-branch)
      [ $# -ge 2 ] || { usage; exit 2; }
      REPAIR_BRANCH="$2"
      shift 2
      ;;
    --push-safe-repairs)
      PUSH_SAFE_REPAIRS=1
      shift
      ;;
    --gh-cmd)
      [ $# -ge 2 ] || { usage; exit 2; }
      GH_CMD="$2"
      shift 2
      ;;
    --root)
      [ $# -ge 2 ] || { usage; exit 2; }
      ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ci-preflight: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$SCOPE" in
  standard|release) ;;
  *)
    echo "ci-preflight: invalid scope '$SCOPE' (expected standard or release)" >&2
    exit 2
    ;;
esac

case "$REPAIR_COMMIT_MODE" in
  none|same-branch|repair-pr) ;;
  *)
    echo "ci-preflight: invalid repair commit mode '$REPAIR_COMMIT_MODE' (expected none, same-branch, or repair-pr)" >&2
    exit 2
    ;;
esac

if [ ! -d "$ROOT" ]; then
  echo "ci-preflight: root not found: $ROOT" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)" || exit 2
cd "$ROOT" || exit 2

if [ "$REPAIR_COMMIT_MODE" = "repair-pr" ] && [ -z "$REPAIR_BRANCH" ]; then
  REPAIR_BRANCH="automation/ci-preflight-repair"
fi

if [ "$REPAIR_COMMIT_MODE" = "same-branch" ] && [ -z "$REPAIR_BRANCH" ]; then
  REPAIR_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$REPAIR_BRANCH" = "HEAD" ]; then
    REPAIR_BRANCH=""
  fi
fi

before_status="$(git -C "$ROOT" status --short 2>/dev/null || true)"

add_blocker() {
  blockers+=("$1")
}

ensure_clean_for_auto_commit() {
  if [ "$REPAIR_COMMIT_MODE" = "none" ]; then
    return 0
  fi
  if [ -n "$before_status" ]; then
    echo "FAIL: automated repair commits require a clean pre-repair worktree" >&2
    add_blocker "dirty worktree blocks automated repair commit"
    return 1
  fi
  return 0
}

prepare_repair_branch_if_needed() {
  if [ "$REPAIR_COMMIT_MODE" != "repair-pr" ] || [ "$repair_branch_prepared" -eq 1 ]; then
    return 0
  fi
  ensure_clean_for_auto_commit || return 1
  validate_repair_pr_ownership || {
    add_blocker "human-owned repair PR blocks repair branch"
    return 1
  }
  git -C "$ROOT" switch -C "$REPAIR_BRANCH" HEAD >/dev/null || {
    add_blocker "could not switch to repair branch $REPAIR_BRANCH"
    return 1
  }
  repair_branch_prepared=1
}

run_health_preflight() {
  local health_script="$ROOT/scripts/health-check.sh"
  local out rc

  if [ ! -x "$health_script" ]; then
    echo "SKIP: scripts/health-check.sh not installed"
    return
  fi

  # health-check.sh is the single severity authority (S2 #641): exit 0 = clean,
  # 1 = at least one blocking finding, 2 = advisory-only findings. Read the exit
  # code; never re-derive severity from the output text or the git branch — the
  # content-aware classifier (S1/S2) already tagged each finding's severity.
  rc=0
  out="$(bash "$health_script" "$ROOT" 2>&1)" || rc=$?
  rc=${rc:-0}

  case "$rc" in
    0)
      echo "PASS: no health-check drift"
      ;;
    2)
      # Advisory-only findings (e.g. Check-7 built-state drift). Surface them so
      # they stay visible, but never block and never reconcile — /consolidate is
      # the reconciler. This holds on every branch; severity is intrinsic to the
      # finding, so there is no in-flight vs. integration special case.
      echo "ADVISORY: health-check reported advisory findings (non-blocking):"
      printf '%s\n' "$out" | grep -F '⚠' | sed 's/^/  /'
      ;;
    1)
      echo "BLOCKER: health-check reported blocking findings"
      printf '%s\n' "$out" | grep -F '✗' | sed 's/^/  /'
      add_blocker "blocking health-check findings"
      ;;
    *)
      # Defensive: an unexpected exit code (crash, usage error) is treated as
      # blocking — fail closed rather than waving an unknown state through.
      echo "BLOCKER: health-check exited $rc (unexpected); treating as blocking"
      printf '%s\n' "$out" | sed 's/^/  /'
      add_blocker "health-check exited $rc (unexpected)"
      ;;
  esac
}

run_coverage_preflight() {
  local validator="$ROOT/scripts/validate-coverage-manifest.sh"
  local generator="$ROOT/scripts/generate-coverage.sh"
  local out rc

  if [ ! -x "$validator" ]; then
    echo "SKIP: scripts/validate-coverage-manifest.sh not installed"
    return
  fi

  rc=0
  out="$(bash "$validator" 2>&1)" || rc=$?
  rc=${rc:-0}
  if [ "$rc" -eq 0 ]; then
    echo "PASS: contract coverage manifest fresh"
    return
  fi

  if ! printf '%s\n' "$out" | grep -Fq 'COVERAGE-MANIFEST-DRIFT'; then
    printf '%s\n' "$out" >&2
    add_blocker "contract coverage validation failed"
    return
  fi

  echo "BLOCKER: contract coverage manifest drift"
  if [ "$APPLY_SAFE_REPAIRS" -ne 1 ]; then
    add_blocker "contract coverage manifest drift"
    return
  fi
  if [ ! -x "$generator" ]; then
    add_blocker "coverage drift repair unavailable: scripts/generate-coverage.sh missing"
    return
  fi

  ensure_clean_for_auto_commit || return
  prepare_repair_branch_if_needed || return
  echo "REPAIR: bash scripts/generate-coverage.sh"
  bash "$generator" || {
    add_blocker "coverage drift repair failed"
    return
  }
  repair_applied=1

  rc=0
  out="$(bash "$validator" 2>&1)" || rc=$?
  rc=${rc:-0}
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    add_blocker "contract coverage manifest drift remains after repair"
    return
  fi

  echo "PASS: contract coverage manifest repaired"
}

run_release_scope() {
  local script
  for script in \
    "$ROOT/scripts/_smoke-test-nightly-release-workflow.sh" \
    "$ROOT/scripts/_smoke-test-contract-update-release-candidate.sh"
  do
    if [ ! -x "$script" ]; then
      add_blocker "release blocker: $(basename "$script") missing"
      continue
    fi
    if ! bash "$script"; then
      echo "BLOCKER: Release blocker from $(basename "$script")"
      add_blocker "release blocker: $(basename "$script")"
    fi
  done
}

changed_paths() {
  {
    git -C "$ROOT" diff --name-only
    git -C "$ROOT" ls-files --others --exclude-standard
  } 2>/dev/null | sort -u
}

json_first_field() {
  local field="$1"
  python3 -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
if data:
    value = data[0].get(field, "")
    print("" if value is None else value)
' "$field"
}

open_pr_number() {
  json_first_field number
}

open_pr_body() {
  json_first_field body
}

filter_same_repo_pr() {
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
matches = [item for item in data if item.get("isCrossRepository") is not True]
print(json.dumps(matches[:1]))
'
}

render_repair_pr_body() {
  {
    echo "$REPAIR_PR_MARKER"
    echo ""
    echo "## CI Preflight Repair"
    echo ""
    echo "This bot-owned PR records deterministic safe repair output from"
    echo "\`scripts/ci-preflight.sh\`."
    echo ""
    echo "The original run stopped before expensive CI. Merge this PR, then let"
    echo "nightly or manual CI validate the repaired commit in a fresh run."
  }
}

upsert_repair_pr() {
  local pr_json number body body_file

  validate_repair_pr_ownership || return $?
  pr_json="$(repair_pr_json)" || return 1
  number="$(printf '%s' "$pr_json" | open_pr_number)"

  body_file="$(mktemp)"
  render_repair_pr_body >"$body_file"
  if [ -n "$number" ]; then
    "$GH_CMD" pr edit "$number" --title "$REPAIR_PR_TITLE" --body-file "$body_file"
  else
    "$GH_CMD" pr create --base main --head "$REPAIR_BRANCH" --title "$REPAIR_PR_TITLE" --body-file "$body_file"
  fi
  rm -f "$body_file"
}

repair_pr_json() {
  command -v "$GH_CMD" >/dev/null 2>&1 || {
    echo "ci-preflight: provider command not found: $GH_CMD" >&2
    return 2
  }

  "$GH_CMD" pr list --state open --head "$REPAIR_BRANCH" --json number,body,isCrossRepository --limit 20 | filter_same_repo_pr
}

validate_repair_pr_ownership() {
  local pr_json number body

  pr_json="$(repair_pr_json)" || return $?
  number="$(printf '%s' "$pr_json" | open_pr_number)"
  if [ -n "$number" ]; then
    body="$(printf '%s' "$pr_json" | open_pr_body)"
    if ! printf '%s\n' "$body" | grep -Fq "$REPAIR_PR_MARKER"; then
      echo "FAIL: human-owned repair PR #$number lacks generated marker; refusing to push repair branch" >&2
      return 1
    fi
  fi
}

commit_repair_changes() {
  local paths remote_sha lease
  paths=()
  while IFS= read -r path; do
    paths+=("$path")
  done < <(changed_paths)
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "WARN: repair mode requested but no changed paths were found"
    return 0
  fi

  git -C "$ROOT" add -- "${paths[@]}" || return 1
  if git -C "$ROOT" diff --cached --quiet; then
    echo "WARN: repair mode requested but no staged paths were found"
    return 0
  fi

  git -C "$ROOT" -c user.name="$BOT_AUTHOR" -c user.email="$BOT_EMAIL" \
    commit -m "$COMMIT_MESSAGE" >/dev/null || return 1
  echo "PREFLIGHT REPAIR COMMITTED: $(git -C "$ROOT" rev-parse --short HEAD)"

  case "$REPAIR_COMMIT_MODE" in
    same-branch)
      if [ "$PUSH_SAFE_REPAIRS" -eq 1 ]; then
        if [ -z "$REPAIR_BRANCH" ]; then
          echo "ci-preflight: --push-safe-repairs requires --repair-branch for same-branch mode" >&2
          return 2
        fi
        git -C "$ROOT" push origin "HEAD:refs/heads/$REPAIR_BRANCH" >/dev/null || return 1
        echo "PREFLIGHT REPAIR PUSHED: $REPAIR_BRANCH"
      fi
      ;;
    repair-pr)
      remote_sha="$(git -C "$ROOT" ls-remote --heads origin "$REPAIR_BRANCH" | awk 'NR == 1 { print $1 }')"
      if [ -n "$remote_sha" ]; then
        lease="refs/heads/$REPAIR_BRANCH:$remote_sha"
      else
        lease="refs/heads/$REPAIR_BRANCH:"
      fi
      git -C "$ROOT" push --force-with-lease="$lease" origin "HEAD:refs/heads/$REPAIR_BRANCH" >/dev/null || return 1
      echo "PREFLIGHT REPAIR PUSHED: $REPAIR_BRANCH"
      upsert_repair_pr || return $?
      ;;
  esac
}

echo "=== CI preflight ==="
echo "scope=$SCOPE"

run_health_preflight
run_coverage_preflight

if [ "${#blockers[@]}" -eq 0 ] && [ "$SCOPE" = "release" ]; then
  if [ "$repair_applied" -eq 0 ] || [ "$CONTINUE_AFTER_REPAIR" -eq 1 ]; then
    run_release_scope
  fi
fi

after_status="$(git -C "$ROOT" status --short 2>/dev/null || true)"

if [ "${#blockers[@]}" -gt 0 ]; then
  echo "PREFLIGHT BLOCKED"
  printf '  - %s\n' "${blockers[@]}"
  exit 1
fi

if [ "$repair_applied" -eq 1 ] && [ -n "$after_status" ]; then
  echo "Repair changed paths:"
  changed_paths | sed 's/^/  /'

  if [ "$REPAIR_COMMIT_MODE" != "none" ]; then
    commit_repair_changes || exit $?
    if [ "$CONTINUE_AFTER_REPAIR" -eq 1 ]; then
      echo "PREFLIGHT OK"
      exit 0
    fi
    echo "PREFLIGHT STOP: repair commit requires a fresh CI run"
    exit 1
  fi

  if [ "$CONTINUE_AFTER_REPAIR" -eq 1 ]; then
    echo "PREFLIGHT OK"
    exit 0
  fi

  echo "PREFLIGHT STOP: repair output requires review"
  exit 1
fi

echo "PREFLIGHT OK"
exit 0
