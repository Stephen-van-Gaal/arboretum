#!/usr/bin/env bash
# owner: session-handoff
# stop-handoff-nudge.sh — Claude Code `Stop` hook (plugin-provided).
# Once per session, when in-flight work exists on a feature branch and
# no handoff was captured, emit a non-blocking nudge so the session
# offers /handoff (design §4.7). All checks are local — no gh.
set -euo pipefail
cat >/dev/null 2>&1 || true   # drain hook stdin (JSON); session id not needed

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in ""|main|master) exit 0 ;; esac

mark_dir="$PROJECT_DIR/.arboretum"
[ -f "$mark_dir/handoff-done" ]   && exit 0   # handoff already captured
[ -f "$mark_dir/handoff-nudged" ] && exit 0   # already nudged this session

# In-flight signal: uncommitted changes (the decisive at-risk case).
[ -z "$(git status --porcelain 2>/dev/null)" ] && exit 0

mkdir -p "$mark_dir" 2>/dev/null || exit 0
touch "$mark_dir/handoff-nudged"

# Non-blocking additionalContext — advisory, never blocks the stop
# (consistent with /handoff being "advisory, never gated"). See plan
# Task 0 / spec §7: confirm this surfaces; else fall back to a
# decision:block nudge.
safe_branch="${branch//\\/\\\\}"        # escape backslashes first
safe_branch="${safe_branch//\"/\\\"}"   # then double-quotes
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":\"In-flight work on branch ${safe_branch} has no session handoff captured this session. Offer to run /handoff so the next session is oriented.\"}}"
exit 0
