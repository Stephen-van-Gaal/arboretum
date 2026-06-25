#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# classify-pr-change.sh — classify a change set as 'docs-config' or 'code',
# for the tiered merge handoff in /land.
#   classify-pr-change.sh <base-ref>      # classify git diff <base>...HEAD
#   classify-pr-change.sh --files-from -  # classify a newline-separated list on stdin
# Prints exactly one of: docs-config | code
set -euo pipefail

classify() { # reads file paths on stdin
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      skills/*|.claude/skills/*) echo "code"; return 0 ;;  # skill files change agent behavior
      .github/workflows/*) echo "code"; return 0 ;;        # CI definitions change repo behavior
      *.md|*.txt|docs/*|.github/*|*.yml|*.yaml|*.json|.gitignore|LICENSE) ;;
      *) echo "code"; return 0 ;;
    esac
  done
  echo "docs-config"   # no code files seen (incl. empty diff) — safe default
}

if [ "${1:-}" = "--files-from" ]; then
  if [ "${2:--}" = "-" ]; then
    classify          # stdin is already the pipe
  else
    classify < "$2"
  fi
else
  base="${1:?usage: classify-pr-change.sh <base-ref> | --files-from <file>}"
  git diff "$base...HEAD" --name-only | classify
fi
