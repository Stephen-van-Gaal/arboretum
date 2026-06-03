#!/usr/bin/env bash
# owner: git-workflow-tooling
# Smoke test for release-intent workflow prose across Arboretum skills.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

require_grep() {
  local pattern="$1" path="$2" label="$3"
  if grep -q "$pattern" "$path"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    fail=1
  fi
}

require_grep '## Release Intent' "$ROOT/skills/pr/SKILL.md" "/pr renders Release Intent section"
require_grep 'release-impact' "$ROOT/skills/pr/SKILL.md" "/pr mentions release-impact"
require_grep 'scripts/read-release-intent.sh' "$ROOT/skills/pr/SKILL.md" "/pr validates with read-release-intent"
require_grep 'patch.*minor.*major' "$ROOT/skills/pr/SKILL.md" "/pr offers patch minor major choices"
require_grep 'release pending' "$ROOT/skills/finish/SKILL.md" "/finish surfaces release pending"
require_grep 'release pending' "$ROOT/skills/land/SKILL.md" "/land surfaces release pending"
require_grep 'release pending' "$ROOT/skills/cleanup/SKILL.md" "/cleanup surfaces release pending"
require_grep 'prepare-release-package.sh' "$ROOT/skills/cleanup/SKILL.md" "/cleanup points at Release Package helper"

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
