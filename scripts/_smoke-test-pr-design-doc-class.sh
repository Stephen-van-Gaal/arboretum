#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Prose smoke: /pr recognizes a design-doc PR class via the shared detector
# detect-design-doc-pr.sh and requests review with --design-doc, in one shell
# block (the flag is a shell var that must not cross a fence). Detection logic
# itself is tested in _smoke-test-detect-design-doc-pr.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/pr/SKILL.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }

grep -qiE 'design-doc PR' "$SKILL" \
  || note "/pr does not mention the design-doc PR class"
grep -qE 'detect-design-doc-pr\.sh' "$SKILL" \
  || note "/pr does not delegate to the shared detect-design-doc-pr.sh"
grep -qE 'request-review\.sh[^\n]*--design-doc|request-review\.sh[^\n]*\$DESIGN_DOC_FLAG' "$SKILL" \
  || note "/pr does not pass the design-doc flag into request-review.sh"
# The flag must be set and consumed in one Bash invocation (cross-fence risk).
grep -qiE 'one .*(shell|Bash) (block|invocation)|same Bash invocation|shell state does not persist' "$SKILL" \
  || note "/pr does not require detection + request in one shell block (cross-fence risk)"

[ "$fail" -eq 0 ] && echo "PASS: pr-design-doc-class" || exit 1
