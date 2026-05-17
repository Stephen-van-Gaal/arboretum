#!/usr/bin/env bash
# owner: session-handoff
# handoff-commit-wip.sh — If the working tree is dirty, commit
# everything into a `wip: handoff` commit and push the branch, so
# in-flight work survives a machine switch (design §4.4). A clean
# tree is a reported no-op. A stash is never used — machine-local.
#
# The CALLER (the /handoff skill) is responsible for getting the
# human's confirmation before invoking this; this script just acts.
#
# Usage: handoff-commit-wip.sh [project-dir]
# Output (stdout): the short SHA of the wip commit, or "clean tree …".
# Exit: 0 ok; 1 not a git repo / on main|master; 2 commit/push failed.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "handoff-commit-wip.sh requires bash" >&2; exit 1; }
PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" || { echo "not a directory: $PROJECT_DIR" >&2; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) \
  || { echo "not a git repository" >&2; exit 1; }
case "$branch" in
  main|master) echo "refusing to wip-commit on $branch" >&2; exit 1 ;;
esac

if [ -z "$(git status --porcelain)" ]; then
  echo "clean tree — nothing to commit"
  exit 0
fi

git add -A
git commit -q -m "wip: handoff $(date -u +%Y-%m-%d)" \
  || { echo "wip commit failed" >&2; exit 2; }

if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git push -q || { echo "push failed" >&2; exit 2; }
else
  remote=$(git remote | head -n 1)
  [ -n "$remote" ] || { echo "push failed: no git remote configured" >&2; exit 2; }
  git push -q -u "$remote" "$branch" || { echo "push failed (no upstream)" >&2; exit 2; }
fi

git rev-parse --short HEAD
exit 0
