#!/usr/bin/env bash
# owner: session-handoff
# stop-handoff-nudge.sh — Claude Code `Stop` hook (plugin-provided).
# Once per session, when in-flight work exists on a feature branch and
# no handoff was captured, emit a non-blocking nudge reminding the user
# to run /handoff (design §4.7). All checks are local — no gh.
set -euo pipefail

# Read the hook payload from stdin and pull out the session id. The
# `Stop` hook receives a JSON object whose `session_id` is a flat
# string field; extract it without a jq/python dependency so the
# per-turn cost stays a couple of shell builtins.
input=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$input" \
  | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
  | head -n1)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in ""|main|master) exit 0 ;; esac

mark_dir="$PROJECT_DIR/.arboretum"
[ -f "$mark_dir/handoff-done" ] && exit 0   # handoff already captured

# The nudge marker is stamped with the session id that wrote it, so
# the "already nudged" short-circuit is scoped to a single session
# even when nothing clears the marker between sessions — the boot-time
# clear in session-start.sh is a project hook, absent downstream.
nudged="$mark_dir/handoff-nudged"
if [ -f "$nudged" ] && [ "$(cat "$nudged" 2>/dev/null || true)" = "$session_id" ]; then
  exit 0   # already nudged this session
fi

# In-flight signal: uncommitted changes (the decisive at-risk case).
[ -z "$(git status --porcelain 2>/dev/null)" ] && exit 0

mkdir -p "$mark_dir" 2>/dev/null || exit 0
printf '%s' "$session_id" > "$nudged"

# Emit a non-blocking `systemMessage` — the correct `Stop` output
# channel for an advisory, user-visible nudge. A `Stop` hook has no
# `additionalContext` channel (the turn is already over), and a
# `decision:"block"` nudge would force the turn to continue,
# contradicting /handoff being "advisory, never gated".
safe_branch="${branch//\\/\\\\}"        # escape backslashes first
safe_branch="${safe_branch//\"/\\\"}"   # then double-quotes
printf '%s\n' "{\"systemMessage\":\"In-flight work on branch ${safe_branch} has no session handoff captured. Consider /handoff so the next session is oriented.\"}"
exit 0
