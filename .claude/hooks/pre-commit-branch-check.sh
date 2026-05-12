#!/usr/bin/env bash
# PreToolUse hook for Bash: block git commit on protected branches.
#
# Intercepts Bash tool calls containing "git commit" and checks
# the current branch against a protected list (main, master).
# Blocking: exits 2 on protected branch.
#
# Limitation: pattern match on command string is best-effort.
# The CLAUDE.md instruction is the primary control; this hook
# is defense-in-depth, not a security boundary.

set -euo pipefail

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Layer 2+ only — skip for Layer 0-1 projects
LAYER=$(sed -n 's/^layer:[[:space:]]*\([0-9]\).*/\1/p' "$PROJECT_DIR/.arboretum.yml" 2>/dev/null)
LAYER="${LAYER:-0}"
[ "$LAYER" -lt 2 ] && exit 0

# Only fire on commands containing "git commit"
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
  exit 0
fi

# ── Check current branch ─────────────────────────────────────────────

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Protected branches — edit this list to customize
PROTECTED_BRANCHES=("main" "master")

for protected in "${PROTECTED_BRANCHES[@]}"; do
  if [ "$BRANCH" = "$protected" ]; then
    echo "[Branch Protection] Cannot commit to '$BRANCH'."
    echo "  → Why: All work happens on feature branches for clean history and PR-based review."
    echo "    Run: git checkout -b feat/your-feature."
    exit 2
  fi
done

exit 0
