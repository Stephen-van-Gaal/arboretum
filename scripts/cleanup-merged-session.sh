#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "cleanup-merged-session.sh requires bash" >&2; exit 2; }

usage() {
  cat <<'USAGE'
cleanup-merged-session
Usage: bash scripts/cleanup-merged-session.sh [--branch <name>] [--worktree <path>] [--remove-active-worktree] [--plan | --execute]

  --plan      Read-only: run every gate and emit plan=ready/plan=blocked; mutate nothing.
  --execute   Default. Re-prove every gate, then perform cleanup. Mutually exclusive with --plan.
USAGE
}

# Gate failures (exit 1) are mode-aware: plan=blocked under --plan, else cleanup=skipped.
skip() {
  if [ "${MODE:-execute}" = plan ]; then
    echo "plan=blocked reason=$1"
  else
    echo "cleanup=skipped reason=$1"
  fi
}

# Invocation / setup / tool errors (exit 2) are not gate blocks — always cleanup=skipped,
# regardless of mode, so a usage error never masquerades as a plan=blocked safety refusal.
arg_err() {
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
MODE=execute
MODE_SET=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ -n "${2:-}" ] || { arg_err "bad-arg"; usage; exit 2; }
      TARGET_BRANCH="$2"
      BRANCH_EXPLICIT=true
      shift 2
      ;;
    --worktree)
      [ -n "${2:-}" ] || { arg_err "bad-arg"; usage; exit 2; }
      TARGET_WORKTREE="$2"
      shift 2
      ;;
    --remove-active-worktree)
      REMOVE_ACTIVE=true
      shift
      ;;
    --plan)
      [ "$MODE_SET" = true ] && [ "$MODE" != plan ] && { arg_err "mode-conflict"; exit 2; }
      MODE=plan
      MODE_SET=true
      shift
      ;;
    --execute)
      [ "$MODE_SET" = true ] && [ "$MODE" != execute ] && { arg_err "mode-conflict"; exit 2; }
      MODE=execute
      MODE_SET=true
      shift
      ;;
    *)
      arg_err "bad-arg"
      usage
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROADMAP_LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$ROADMAP_LIB" ] || { arg_err "missing-roadmap-lib"; exit 2; }

SESSION_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$SESSION_ROOT" ] || { arg_err "not-git-worktree"; exit 2; }

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
# The primary (main) worktree is always git's first worktree-list entry and is
# the only safe control: checking the default branch out there never clobbers an
# unrelated linked worktree (issue #741). When the target IS the primary,
# control == target, which routes --execute to the in-place keep path. Emit the
# realpath so the bash comparison against TARGET_WORKTREE (pwd -P) is exact.
control = entries[0]["realpath"] if entries else ""
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
# --execute on the active worktree requires the explicit flag. --plan is read-only,
# so it must reach the plan result and report active=yes regardless of the flag —
# the main thread (not the driver) performs the terminal removal with the flag.
if [ "$MODE" != plan ] && [ "$TARGET_WORKTREE" != "$CONTROL_WORKTREE" ] && [ "$TARGET_WORKTREE" = "$ACTIVE_ROOT" ] && [ "$REMOVE_ACTIVE" != true ]; then
  skip "active-worktree-needs-flag"
  exit 1
fi

# shellcheck source=scripts/roadmap/lib.sh
source "$ROADMAP_LIB"
BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$SESSION_ROOT")}"
# Emit the structured unsupported-backend token before roadmap_require_backend,
# which would otherwise exit 2 with only raw stderr and no cleanup=skipped reason.
case "$BACKEND" in
  github|azure-devops) ;;
  *) arg_err "unsupported-backend"; exit 2 ;;
esac
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
    arg_err "unsupported-backend"
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

# Defense in depth (#741): when cleaning up a linked worktree, the control is the
# primary tree. Never check the default branch out over the primary's own
# in-flight work — proceed only when the control is *exactly* on the default
# branch. A non-default branch OR a detached HEAD (empty CONTROL_BRANCH, itself
# in-flight work at a specific commit) both refuse. (When the target IS the
# primary, control == target and its branch is the just-merged target branch we
# intend to replace with the default, so this guard is skipped.)
if [ "$TARGET_WORKTREE" != "$CONTROL_WORKTREE" ]; then
  CONTROL_BRANCH="$(git -C "$CONTROL_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$CONTROL_BRANCH" != "$DEFAULT_BRANCH" ]; then
    skip "control-worktree-not-on-default"
    exit 1
  fi
fi

if [ "$MODE" = plan ]; then
  if [ "$TARGET_WORKTREE" = "$CONTROL_WORKTREE" ]; then
    REMOVE_WT=no
  else
    REMOVE_WT=yes
  fi
  if [ "$TARGET_WORKTREE" = "$ACTIVE_ROOT" ]; then
    ACTIVE_WT=yes
  else
    ACTIVE_WT=no
  fi
  DEFAULT_TIP="$(git -C "$SESSION_ROOT" rev-parse --verify "refs/remotes/origin/$DEFAULT_BRANCH^{commit}" 2>/dev/null \
    || git -C "$SESSION_ROOT" rev-parse --verify "refs/heads/$DEFAULT_BRANCH^{commit}" 2>/dev/null || true)"
  if [ -n "$DEFAULT_TIP" ] && git -C "$SESSION_ROOT" merge-base --is-ancestor "$LOCAL_SHA" "$DEFAULT_TIP" 2>/dev/null; then
    BRANCH_MODE=safe
  else
    BRANCH_MODE=force-squash
  fi
  echo "plan=ready branch=$TARGET_BRANCH worktree=$TARGET_WORKTREE branch-mode=$BRANCH_MODE remove-worktree=$REMOVE_WT active=$ACTIVE_WT"
  exit 0
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
