#!/usr/bin/env bash
# owner: git-workflow-tooling
# _smoke-test-classify-pr-change.sh — assert classify-pr-change.sh maps
# file lists to the correct merge tier (docs-config | code).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="$SCRIPT_DIR/classify-pr-change.sh"
fail_count=0
check() { # <label> <expected> <files...>
  local label="$1" expected="$2"; shift 2
  local got
  got=$(printf '%s\n' "$@" | bash "$CLASSIFY" --files-from -)
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $label — expected '$expected', got '$got'" >&2
    ((fail_count++)) || true
  fi
}
check "docs only"           docs-config "README.md" "docs/x.md"
check "issue template"      docs-config ".github/ISSUE_TEMPLATE/foo.yml" "package.json"
check "ci workflow"         code        ".github/workflows/ci.yml"
check "one code file"       code        "README.md" "scripts/foo.sh"
check "skill change"        code        "skills/land/SKILL.md"
check "claude skill change" code        ".claude/skills/dev-manage-workflows/SKILL.md"
check "empty diff"          docs-config
if [ "$fail_count" -gt 0 ]; then
  echo "FAIL: $fail_count case(s) failed" >&2; exit 1
fi
echo "PASS: classify-pr-change.sh — 7 cases"
