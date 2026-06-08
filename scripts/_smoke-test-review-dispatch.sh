#!/usr/bin/env bash
# owner: review-stage
# _smoke-test-review-dispatch.sh — assert the lane planner emits, in run order:
#   ai-surface (only when AI-facing surface changed), general-security (always),
#   correctness (only when the diff contains code per classify-pr-change.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="$SCRIPT_DIR/review-dispatch.sh"
fail_count=0
check() { # <label> <expected-newline-joined> <files...>
  local label="$1" expected="$2"; shift 2
  local got
  got=$(printf '%s\n' "$@" | bash "$PLAN" --files-from -)
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $label — expected '$expected', got '$got'" >&2
    ((fail_count++)) || true
  fi
}
check "ai-facing code (skill)" $'ai-surface\ngeneral-security\ncorrectness' "skills/finish/SKILL.md"
check "ai-facing code (hook)"  $'ai-surface\ngeneral-security\ncorrectness' ".claude/hooks/session-start.sh"
check "ai-facing docs (md)"    $'ai-surface\ngeneral-security'              "CLAUDE.md"
check "conventional code"      $'general-security\ncorrectness'            "src/app.ts"
check "docs only"              "general-security"                          "README.md" "docs/x.md"
check "empty diff"             "general-security"
check "mixed surface+code"     $'ai-surface\ngeneral-security\ncorrectness' "skills/finish/SKILL.md" "src/app.ts"
if [ "$fail_count" -gt 0 ]; then
  echo "FAIL: $fail_count case(s) failed" >&2; exit 1
fi
echo "PASS: review-dispatch.sh — 7 cases"
