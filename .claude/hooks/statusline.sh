#!/usr/bin/env bash
# owner: pipeline-state-tracking
# statusline.sh — Claude Code statusline: render `[#N /stage]` from
# .arboretum/active-stage-cache.json (WS9 design D6). Refreshes the
# cache in the background when stale (>30s).
#
# Source of truth: the issue body's current-stage header (written by
# scripts/log-stage.sh). This hook reads the cache that
# scripts/refresh-stage-cache.sh populates from that header.
set -euo pipefail
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE="$PROJECT_DIR/.arboretum/active-stage-cache.json"
REFRESH="$PROJECT_DIR/scripts/refresh-stage-cache.sh"
TTL=30  # seconds — D6/OQ3 cache TTL

if [ -f "$REFRESH" ]; then
  if [ ! -f "$CACHE" ]; then
    # First-call: kick off populate in background (don't block the statusline).
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

[ -f "$CACHE" ] || exit 0

if command -v python3 >/dev/null 2>&1; then
  python3 - "$CACHE" <<'PY'
import json, re, sys
# Defense in depth: cache writer scrubs control chars at source, but
# scrub again here so a hand-edited or older-version cache cannot
# inject ANSI escape sequences into the statusline rendering.
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
issue = c.get("issue"); stage = scrub(c.get("stage"))
if issue and stage:
    print(f"[#{issue} {stage}]")
elif issue:
    print(f"[#{issue}]")
PY
fi
exit 0
