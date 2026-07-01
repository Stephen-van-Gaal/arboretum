#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/workflows/build.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }
grep -qiE 'design-doc|shaping.*PR|Codex review.*design' "$DOC" \
  || note "workflows/build.md does not document design-doc PR review"
grep -qiE 'before .*children|children build' "$DOC" \
  || note "workflows/build.md does not state review happens before children build"
[ "$fail" -eq 0 ] && echo "PASS: design-doc-review-docs" || exit 1
