#!/usr/bin/env bash
# owner: receive-review
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-receive-review.sh — Verify the receive-review wiring contract.
#
# Cases:
#   T1  skills/receive-review/SKILL.md exists
#   T2  Frontmatter declares name: receive-review and owner: receive-review
#   T3  Procedure invokes superpowers:receiving-code-review
#   T4  Procedure embeds the GraphQL resolveReviewThread recipe
#   T5  Procedure surfaces the paired-stub-sync check
#   T6  skills/land/SKILL.md invokes arboretum:receive-review
#   T7  skills/land/SKILL.md no longer carries the inline GraphQL recipe
#       (the recipe moved to the wrapper — single source of truth)
#
# Usage: bash scripts/_smoke-test-receive-review.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/receive-review/SKILL.md"
LAND="$REPO_ROOT/skills/land/SKILL.md"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# T1
[ -f "$SKILL" ] || fail "T1: skills/receive-review/SKILL.md missing"
ok "T1: receive-review SKILL.md exists"

# T2
grep -q "^name: receive-review$" "$SKILL" || fail "T2: missing 'name: receive-review' in frontmatter"
grep -q "^owner: receive-review$" "$SKILL" || fail "T2: missing 'owner: receive-review' in frontmatter"
ok "T2: frontmatter declares correct name + owner"

# T3
grep -q "superpowers:receiving-code-review" "$SKILL" \
  || fail "T3: procedure does not invoke superpowers:receiving-code-review"
ok "T3: procedure delegates to upstream skill"

# T4
grep -q "resolveReviewThread" "$SKILL" \
  || fail "T4: procedure missing GraphQL resolveReviewThread recipe"
ok "T4: procedure embeds GraphQL thread-resolve recipe"

# T5
grep -qi "paired-stub-sync\|paired stub sync" "$SKILL" \
  || fail "T5: procedure missing paired-stub-sync check"
ok "T5: procedure surfaces paired-stub-sync check"

# T6
grep -q "arboretum:receive-review" "$LAND" \
  || fail "T6: skills/land/SKILL.md does not invoke arboretum:receive-review"
ok "T6: /land invokes arboretum:receive-review"

# T7: /land no longer carries the migrated GraphQL recipe (it lives in the wrapper now).
# Marker is the inline `gh api graphql` invocation that opens the recipe code-fence —
# prose mentions of `resolveReviewThread` (e.g. pointing at where the wrapper now owns
# the mutation) are fine; the load-bearing artifact is the executable recipe block.
if grep -q "gh api graphql" "$LAND"; then
  fail "T7: skills/land/SKILL.md still carries inline GraphQL recipe block (should be in wrapper only)"
fi
ok "T7: /land no longer carries inline GraphQL recipe (single source of truth in wrapper)"

echo
echo "All cases passed."
