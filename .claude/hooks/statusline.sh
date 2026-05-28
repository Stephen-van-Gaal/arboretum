#!/usr/bin/env bash
# owner: pipeline-state-tracking
# statusline.sh — Claude Code statusline renderer. Emits the project's
# full status line on a single line: <model>  |  ts HH:MM  |
# <project>/<branch>  |  ctx <N>%  |  5h:<N>% 7d:<N>%  |  wt:<name>  |
# [#<issue> /<stage>].
#
# The hook is a *replacement* for Claude Code's default statusline, so
# we must re-emit the default-equivalent fields (model, project, branch,
# ctx %, rate-limit %, worktree) alongside the arboretum-specific chip.
# See docs/specs/pipeline-state-tracking.spec.md ## Read paths #1.
#
# Input: JSON session payload on stdin (schema documented at
# https://code.claude.com/docs/en/statusline). Cache file at
# .arboretum/active-stage-cache.json provides the chip data.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE="$PROJECT_DIR/.arboretum/active-stage-cache.json"
REFRESH="$PROJECT_DIR/scripts/refresh-stage-cache.sh"
TTL=30  # seconds — D6/OQ3 chip cache TTL

# Background refresh of the chip cache when stale (>TTL) or absent.
if [ -f "$REFRESH" ]; then
  if [ ! -f "$CACHE" ]; then
    ( bash "$REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
    disown 2>/dev/null || true
  else
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -gt "$TTL" ]; then
      ( bash "$REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
      disown 2>/dev/null || true
    fi
  fi
fi

command -v python3 >/dev/null 2>&1 || exit 0

# Read entire stdin payload (Claude Code pipes it to us).
STDIN_JSON="$(cat 2>/dev/null || true)"

# Resolve current git branch in the project_dir if it's a git repo. We
# do this in bash (not python) to keep the python heredoc free of
# subprocess plumbing. Empty string when not in a repo.
GIT_BRANCH=""
if [ -d "$PROJECT_DIR/.git" ] || git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

export STDIN_JSON CACHE GIT_BRANCH PROJECT_DIR

python3 <<'PY'
import json, os, re, sys, time

# Defense in depth: scrub ASCII control characters from every
# string field surfaced to the statusline. Mirror of the regex in
# scripts/refresh-stage-cache.sh and .claude/hooks/session-start.sh.
# See docs/specs/pipeline-state-tracking.spec.md ## Defense in depth.
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")

def scrub(s):
    if not isinstance(s, str):
        return ""
    return _CTRL.sub("", s)

def pct_int(v):
    """Truncate a numeric percentage to an integer; return None if absent/non-numeric."""
    if v is None:
        return None
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None

raw = os.environ.get("STDIN_JSON") or ""
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}

# --- Segment 1: model ---
model = scrub((data.get("model") or {}).get("display_name") or "")

# --- Segment 2: ts (wall-clock, local, HH:MM) ---
# Always present — the ambient "what time is it now" surface (issue #363).
# Derived from local system time only; no external content, so no scrub.
ts = time.strftime("%H:%M")

# --- Segment 3: project/branch ---
workspace = data.get("workspace") or {}
project_dir = workspace.get("project_dir") or data.get("cwd") or os.environ.get("PROJECT_DIR") or ""
project = scrub(os.path.basename(project_dir.rstrip("/"))) if project_dir else ""
branch = scrub(os.environ.get("GIT_BRANCH", ""))
if project and branch:
    proj_branch = f"{project}/{branch}"
elif project:
    proj_branch = project
else:
    proj_branch = ""

# --- Segment 4: ctx % ---
ctx_pct = pct_int((data.get("context_window") or {}).get("used_percentage"))

# --- Segment 5: 5h / 7d rate-limit % ---
rl = data.get("rate_limits") or {}
five = pct_int((rl.get("five_hour") or {}).get("used_percentage"))
seven = pct_int((rl.get("seven_day") or {}).get("used_percentage"))

# --- Segment 6: worktree ---
# workspace.git_worktree covers any linked worktree (preferred);
# worktree.name covers --worktree sessions only.
wt = scrub(workspace.get("git_worktree") or (data.get("worktree") or {}).get("name") or "")

# --- Segment 7: pipeline-state chip ---
chip = ""
cache_path = os.environ.get("CACHE") or ""
if cache_path and os.path.exists(cache_path):
    try:
        with open(cache_path) as f:
            c = json.load(f)
        issue = c.get("issue")
        stage = scrub(c.get("stage") or "")
        if issue and stage:
            chip = f"[#{issue} {stage}]"
        elif issue:
            chip = f"[#{issue}]"
    except Exception:
        pass

# Compose the line. Absent optional segments collapse their separators
# so the line never has a stranded `  |  `.
segments = []
if model:
    segments.append(model)
segments.append(f"ts {ts}")
if proj_branch:
    segments.append(proj_branch)
if ctx_pct is not None:
    segments.append(f"ctx {ctx_pct}%")
if five is not None and seven is not None:
    segments.append(f"5h:{five}% 7d:{seven}%")
if wt:
    segments.append(f"wt:{wt}")
if chip:
    segments.append(chip)

if segments:
    sys.stdout.write("  |  ".join(segments))
PY
exit 0
