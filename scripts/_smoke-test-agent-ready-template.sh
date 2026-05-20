#!/usr/bin/env bash
# owner: roadmap
# Smoke test for .github/ISSUE_TEMPLATE/agent-ready.md
#
# Asserts the template has valid YAML frontmatter and every required
# readiness section, so the "agent-ready issue" tier stays well-formed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/.github/ISSUE_TEMPLATE/agent-ready.md"

[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE not found" >&2; exit 1; }

fail=0

# Test 1: frontmatter delimiters present
first_line="$(head -n1 "$TEMPLATE")"
if [ "$first_line" = "---" ]; then
  echo "PASS  frontmatter opens with ---"
else
  echo "FAIL  frontmatter must open with --- (got: '$first_line')"
  fail=1
fi
fm_delims="$(grep -c '^---$' "$TEMPLATE" || true)"
if [ "$fm_delims" -ge 2 ]; then
  echo "PASS  frontmatter has opening and closing ---"
else
  echo "FAIL  frontmatter missing closing --- (found $fm_delims delimiters)"
  fail=1
fi

# Test 2: required frontmatter keys
for key in "name:" "about:" "labels:"; do
  if grep -q "^$key" "$TEMPLATE"; then
    echo "PASS  frontmatter key: $key"
  else
    echo "FAIL  frontmatter key missing: $key"
    fail=1
  fi
done

# Test 3: carries horizon:next, never the earned agent-ready label
if grep -q 'horizon:next' "$TEMPLATE"; then
  echo "PASS  template labels include horizon:next"
else
  echo "FAIL  template should label horizon:next"
  fail=1
fi
if grep -Eq '"agent-ready"|labels:.*agent-ready' "$TEMPLATE"; then
  echo "FAIL  template must NOT pre-apply agent-ready (earned via /roadmap agent-prep)"
  fail=1
else
  echo "PASS  template does not pre-apply agent-ready"
fi

# Test 4: every required readiness section heading is present
for section in \
  "## Context" \
  "## Acceptance criteria" \
  "## Technical approach" \
  "## Files and components touched" \
  "## Open questions" \
  "## Embedded context" \
  "## Agent-readiness self-check" \
  "## Spec"
do
  if grep -Fxq "$section" "$TEMPLATE"; then
    echo "PASS  section: $section"
  else
    echo "FAIL  section missing: $section"
    fail=1
  fi
done

exit $fail
