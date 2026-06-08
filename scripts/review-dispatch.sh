#!/usr/bin/env bash
# owner: review-stage
# review-dispatch.sh — print the B4 lane plan for a change set.
#   review-dispatch.sh <base-ref>
#   review-dispatch.sh --files-from <file|->
# Run order: ai-surface (if AI-facing surface changed), general-security (always),
#            correctness (if the diff contains code).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_ai_facing() { # reads paths on stdin; 0 if any match AI-facing globs
  while IFS= read -r f; do
    case "$f" in
      skills/*|.claude/skills/*|.claude/hooks/*|.githooks/*|scripts/*) return 0 ;;
      CLAUDE.md|AGENTS.md|GEMINI.md) return 0 ;;
    esac
  done
  return 1
}

plan() { # reads paths on stdin
  local files; files="$(cat)"
  if printf '%s\n' "$files" | is_ai_facing; then echo "ai-surface"; fi
  echo "general-security"   # always — safe default
  # correctness lane only when the change set contains code
  if [ "$(printf '%s\n' "$files" | bash "$SCRIPT_DIR/classify-pr-change.sh" --files-from -)" = "code" ]; then
    echo "correctness"
  fi
}

case "${1:-}" in
  --files-from)
    if [ "${2:-}" = "-" ]; then plan; else plan < "$2"; fi ;;
  "")
    echo "usage: review-dispatch.sh <base-ref> | --files-from <file|->" >&2; exit 1 ;;
  *)
    git diff "$1...HEAD" --name-only | plan ;;
esac
