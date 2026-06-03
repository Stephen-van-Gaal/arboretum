#!/usr/bin/env bash
# owner: git-workflow-tooling
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "cleanup-merged-session.sh requires bash" >&2; exit 2; }

usage() {
  cat <<'USAGE'
cleanup-merged-session
Usage: bash scripts/cleanup-merged-session.sh [--branch <name>] [--worktree <path>] [--remove-active-worktree]
USAGE
}

skip() {
  echo "cleanup=skipped reason=$1"
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

TARGET_BRANCH=""
TARGET_WORKTREE=""
BRANCH_EXPLICIT=false
REMOVE_ACTIVE=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ -n "${2:-}" ] || { skip "bad-arg"; usage; exit 2; }
      TARGET_BRANCH="$2"
      BRANCH_EXPLICIT=true
      shift 2
      ;;
    --worktree)
      [ -n "${2:-}" ] || { skip "bad-arg"; usage; exit 2; }
      TARGET_WORKTREE="$2"
      shift 2
      ;;
    --remove-active-worktree)
      REMOVE_ACTIVE=true
      shift
      ;;
    *)
      skip "bad-arg"
      usage
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROADMAP_LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$ROADMAP_LIB" ] || { skip "missing-roadmap-lib"; exit 2; }

SESSION_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$SESSION_ROOT" ] || { skip "not-git-worktree"; exit 2; }

DEFAULT_BRANCH="$(git -C "$SESSION_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
CURRENT_BRANCH="$(git -C "$SESSION_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$TARGET_BRANCH" ] || TARGET_BRANCH="$CURRENT_BRANCH"
[ -n "$TARGET_WORKTREE" ] || TARGET_WORKTREE="$SESSION_ROOT"
if ! TARGET_WORKTREE="$(cd "$TARGET_WORKTREE" 2>/dev/null && pwd -P)"; then
  skip "worktree-missing"
  exit 1
fi

case "$TARGET_BRANCH" in
  ""|HEAD)
    skip "detached-needs-explicit-branch"
    exit 1
    ;;
  main|master)
    skip "protected-branch"
    exit 1
    ;;
esac
if [ "$TARGET_BRANCH" = "$DEFAULT_BRANCH" ]; then
  skip "protected-branch"
  exit 1
fi

TARGET_WORKTREE_BRANCH="$(git -C "$TARGET_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ -n "$TARGET_WORKTREE_BRANCH" ] && [ "$TARGET_WORKTREE_BRANCH" != "$TARGET_BRANCH" ]; then
  skip "worktree-branch-mismatch"
  exit 1
fi
if [ -z "$TARGET_WORKTREE_BRANCH" ] && [ "$BRANCH_EXPLICIT" != true ]; then
  skip "detached-needs-explicit-branch"
  exit 1
fi

if [ -n "$(git -C "$TARGET_WORKTREE" status --porcelain 2>/dev/null || true)" ]; then
  skip "dirty-worktree"
  exit 1
fi

WORKTREES_RAW="$(git -C "$SESSION_ROOT" worktree list --porcelain)"
WORKTREE_INFO="$(WORKTREES_RAW="$WORKTREES_RAW" TARGET_WORKTREE="$TARGET_WORKTREE" python3 <<'PY'
import os

target = os.path.realpath(os.environ["TARGET_WORKTREE"])
entries = []
current = None

for raw in os.environ["WORKTREES_RAW"].splitlines():
    if raw.startswith("worktree "):
        if current is not None:
            entries.append(current)
        path = raw[len("worktree "):]
        current = {"path": path, "realpath": os.path.realpath(path), "locked": False}
    elif current is not None and raw.startswith("locked"):
        current["locked"] = True

if current is not None:
    entries.append(current)

target_entry = next((entry for entry in entries if entry["realpath"] == target), None)
control = next((entry["path"] for entry in entries if entry["realpath"] != target), "")
print(f"target_found={'yes' if target_entry else 'no'}")
print(f"target_locked={'yes' if target_entry and target_entry['locked'] else 'no'}")
print(f"control={control}")
PY
)"

TARGET_FOUND="$(printf '%s\n' "$WORKTREE_INFO" | awk -F= '$1 == "target_found" { print $2; exit }')"
TARGET_LOCKED="$(printf '%s\n' "$WORKTREE_INFO" | awk -F= '$1 == "target_locked" { print $2; exit }')"
CONTROL_WORKTREE="$(printf '%s\n' "$WORKTREE_INFO" | awk -F= '$1 == "control" { print substr($0, index($0, "=") + 1); exit }')"

[ "$TARGET_FOUND" = "yes" ] || { skip "worktree-not-listed"; exit 1; }
if [ "$TARGET_LOCKED" = "yes" ]; then
  skip "locked-worktree"
  exit 1
fi
[ -n "$CONTROL_WORKTREE" ] || CONTROL_WORKTREE="$SESSION_ROOT"

ACTIVE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$ACTIVE_ROOT" ]; then
  ACTIVE_ROOT="$(ACTIVE_ROOT="$ACTIVE_ROOT" python3 <<'PY'
import os
print(os.path.realpath(os.environ["ACTIVE_ROOT"]))
PY
)"
fi
if [ "$TARGET_WORKTREE" != "$CONTROL_WORKTREE" ] && [ "$TARGET_WORKTREE" = "$ACTIVE_ROOT" ] && [ "$REMOVE_ACTIVE" != true ]; then
  skip "active-worktree-needs-flag"
  exit 1
fi

# shellcheck source=scripts/roadmap/lib.sh
source "$ROADMAP_LIB"
BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$SESSION_ROOT")}"
if [ "$BACKEND" = "github" ] && ! command -v gh >/dev/null 2>&1 && [ -x /opt/homebrew/bin/gh ]; then
  PATH="/opt/homebrew/bin:$PATH"
fi
roadmap_require_backend "$BACKEND" >/dev/null || exit 2

LOCAL_SHA="$(git -C "$SESSION_ROOT" rev-parse --verify "refs/heads/$TARGET_BRANCH^{commit}" 2>/dev/null || true)"
[ -n "$LOCAL_SHA" ] || { skip "branch-missing"; exit 1; }

PR_HEAD_SHA=""
case "$BACKEND" in
  github)
    PR_JSON="$(gh pr list --head "$TARGET_BRANCH" --base "$DEFAULT_BRANCH" --state merged --json number,headRefOid,baseRefName --jq '.[0] // empty' 2>/dev/null || true)"
    [ -n "$PR_JSON" ] || { skip "no-merged-pr"; exit 1; }
    PR_HEAD_SHA="$(PR_JSON_RAW="$PR_JSON" python3 <<'PY' || true
import json, sys
import os
raw = os.environ.get("PR_JSON_RAW", "").strip()
if not raw:
    sys.exit(0)
data = json.loads(raw)
if isinstance(data, list):
    data = data[0] if data else {}
print(data.get("headRefOid", ""))
PY
)"
    ;;
  azure-devops)
    PR_JSON="$(az repos pr list --source-branch "$TARGET_BRANCH" --target-branch "$DEFAULT_BRANCH" --status completed --output json 2>/dev/null || true)"
    [ -n "$PR_JSON" ] || { skip "no-completed-pr"; exit 1; }
    PR_HEAD_SHA="$(PR_JSON_RAW="$PR_JSON" python3 <<'PY' || true
import json, sys
import os
raw = os.environ.get("PR_JSON_RAW", "").strip()
if not raw:
    sys.exit(0)
data = json.loads(raw)
first = data[0] if isinstance(data, list) and data else {}
print(first.get("lastMergeSourceCommit", {}).get("commitId", ""))
PY
)"
    ;;
  *)
    skip "unsupported-backend"
    exit 2
    ;;
esac

[ -n "$PR_HEAD_SHA" ] || { skip "missing-provider-head-sha"; exit 1; }
if ! git -C "$SESSION_ROOT" merge-base --is-ancestor "$LOCAL_SHA" "$PR_HEAD_SHA" 2>/dev/null; then
  skip "unproven-local-commits"
  exit 1
fi

if [ "$TARGET_WORKTREE" != "$CONTROL_WORKTREE" ] && [ -n "$(git -C "$CONTROL_WORKTREE" status --porcelain 2>/dev/null || true)" ]; then
  skip "control-worktree-dirty"
  exit 1
fi

git -C "$CONTROL_WORKTREE" checkout "$DEFAULT_BRANCH" >/dev/null 2>&1 || { skip "checkout-default-failed"; exit 1; }
git -C "$CONTROL_WORKTREE" pull --ff-only >/dev/null 2>&1 || { skip "default-ff-pull-failed"; exit 1; }

if [ "$TARGET_WORKTREE" != "$CONTROL_WORKTREE" ]; then
  git -C "$TARGET_WORKTREE" switch --detach >/dev/null 2>&1 || { skip "detach-target-failed"; exit 1; }
fi

if git -C "$CONTROL_WORKTREE" branch -d "$TARGET_BRANCH" >/dev/null 2>&1; then
  echo "branch=deleted mode=safe"
else
  git -C "$CONTROL_WORKTREE" branch -D "$TARGET_BRANCH" >/dev/null 2>&1 || { skip "branch-delete-failed"; exit 1; }
  echo "branch=deleted mode=force-squash"
fi

if [ "$TARGET_WORKTREE" = "$CONTROL_WORKTREE" ]; then
  echo "worktree=kept reason=main-worktree"
  exit 0
fi

if [ "$TARGET_WORKTREE" = "$ACTIVE_ROOT" ] && [ "$REMOVE_ACTIVE" = true ]; then
  if git -C "$CONTROL_WORKTREE" worktree remove "$TARGET_WORKTREE" >/dev/null 2>&1; then
    echo "worktree=removed active=true"
    echo "session=terminal reason=active-worktree-removed action=end-or-reopen-session"
    exit 0
  fi
  echo "worktree=kept reason=remove-failed"
  exit 1
fi

if git -C "$CONTROL_WORKTREE" worktree remove "$TARGET_WORKTREE" >/dev/null 2>&1; then
  echo "worktree=removed active=false"
else
  echo "worktree=kept reason=remove-failed"
  exit 1
fi
