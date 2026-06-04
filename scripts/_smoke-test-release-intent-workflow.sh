#!/usr/bin/env bash
# owner: git-workflow-tooling
# Smoke test that public workflow skills do not carry dev-only release prose.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

forbid_grep() {
  local pattern="$1" path="$2" label="$3"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing file for $label: ${path#$ROOT/}" >&2
    fail=1
    return
  fi
  if grep -q "$pattern" "$path"; then
    echo "FAIL: $label" >&2
    fail=1
  else
    echo "PASS: $label"
  fi
}

forbid_grep '## Release Intent' "$ROOT/skills/pr/SKILL.md" "/pr omits Release Intent section"
forbid_grep 'release-impact' "$ROOT/skills/pr/SKILL.md" "/pr omits release-impact"
forbid_grep 'read-release-intent.sh' "$ROOT/skills/pr/SKILL.md" "/pr omits release-intent parser"
forbid_grep 'release pending' "$ROOT/skills/finish/SKILL.md" "/finish omits release-pending prose"
forbid_grep 'release pending' "$ROOT/skills/land/SKILL.md" "/land omits release-pending prose"
forbid_grep 'release pending' "$ROOT/skills/cleanup/SKILL.md" "/cleanup omits release-pending prose"
forbid_grep 'prepare-release-package.sh' "$ROOT/skills/cleanup/SKILL.md" "/cleanup omits Release Package helper"

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
