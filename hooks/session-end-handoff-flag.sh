#!/usr/bin/env bash
# owner: session-handoff
# session-end-handoff-flag.sh — Claude Code `SessionEnd` hook
# (plugin-provided). SessionEnd is non-interactive, so this only
# RECORDS: if the session ends with uncommitted work on a feature
# branch and no handoff was captured, drop a flag the next
# SessionStart surfaces (design §4.8).
set -euo pipefail
cat >/dev/null 2>&1 || true   # drain hook stdin

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in ""|main|master) exit 0 ;; esac

[ -f "$PROJECT_DIR/.arboretum/handoff-done" ] && exit 0
[ -z "$(git status --porcelain 2>/dev/null)" ] && exit 0

mkdir -p "$PROJECT_DIR/.arboretum" 2>/dev/null || exit 0

# Escape the branch name before embedding it in JSON (a branch may
# legally contain a double-quote or backslash).
safe_branch="${branch//\\/\\\\}"
safe_branch="${safe_branch//\"/\\\"}"
printf '{"branch":"%s","ended_at":"%s"}\n' \
  "$safe_branch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$PROJECT_DIR/.arboretum/handoff-pending.json"
exit 0
