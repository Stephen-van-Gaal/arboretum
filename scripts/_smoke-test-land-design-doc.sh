#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Prose smoke: /land scopes BOTH reviewer-request points (draft-clean ready
# transition + post-fix re-request) to the design-doc class via the shared
# detect-design-doc-pr.sh, so Codex-only scoping holds across the review loop
# (#935 K4), not just at PR open.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/land/SKILL.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }

# Both request points must consult the shared detector — at least two references.
n="$(grep -cE 'detect-design-doc-pr\.sh' "$SKILL")"
[ "$n" -ge 2 ] \
  || note "/land references detect-design-doc-pr.sh $n time(s); expected >=2 (ready-transition + re-request)"
# The re-request path must carry the flag alongside --re-request.
grep -qE 'request-review\.sh[^\n]*--re-request[^\n]*DD_FLAG|request-review\.sh[^\n]*--re-request[^\n]*--design-doc' "$SKILL" \
  || note "/land re-request does not carry the design-doc scope"

[ "$fail" -eq 0 ] && echo "PASS: land-design-doc" || exit 1
