#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-write-agent-brief.sh — Verify the agent-brief writer produces a
# file with the S2 frontmatter shape /build's read-s2-frontmatter.sh accepts.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

WRITE="$REPO_ROOT/scripts/write-agent-brief.sh"
READ_S2="$REPO_ROOT/scripts/read-s2-frontmatter.sh"

# Case 1: happy path — issue 299, task statement on stdin, brief written
cd "$ROOT_TMP"
echo "Rename misleading variable foo to bar in baz.sh" | bash "$WRITE" 299 >/dev/null
BRIEF=".arboretum/agent-briefs/299.md"
[ -f "$BRIEF" ] || fail "case 1 — brief not written at $BRIEF"
ok "case 1 — brief written at expected path"

# Case 2: frontmatter contains all five S2 fields with agent-target defaults
grep -q "^related-issue: 299$" "$BRIEF" || fail "case 2 — missing related-issue" "$(cat "$BRIEF")"
grep -q "^triage: agent-target$" "$BRIEF" || fail "case 2 — missing/wrong triage"
grep -q "^implementation-mode: direct$" "$BRIEF" || fail "case 2 — missing/wrong mode"
grep -q "^plan: null$" "$BRIEF" || fail "case 2 — missing/wrong plan"
grep -q "^test-tiers:" "$BRIEF" || fail "case 2 — missing test-tiers block"
ok "case 2 — frontmatter has all five S2 fields with agent-target defaults"

# Case 2b: tiers default to `yes`, not `n/a` (#695). Asserting `n/a` by default
# under-declares and trips /build's N/A-mutation guard the moment an agent-target
# slice touches a test of that tier. `yes` is the only unconditionally safe
# default (no converse guard); workflow-unification D6 forbids all-tiers-N/A as
# the default.
grep -q "^  unit: yes$" "$BRIEF" || fail "case 2b — unit tier is not 'yes'" "$(cat "$BRIEF")"
grep -q "^  contract: yes$" "$BRIEF" || fail "case 2b — contract tier is not 'yes'" "$(cat "$BRIEF")"
grep -q "^  integration: yes$" "$BRIEF" || fail "case 2b — integration tier is not 'yes'" "$(cat "$BRIEF")"
ok "case 2b — test-tiers default to 'yes' (D6 / #695)"

# Case 3: read-s2-frontmatter.sh accepts the brief
out=$(bash "$READ_S2" "$BRIEF")
echo "$out" | grep -q "^related-issue=299" || fail "case 3 — S2 reader rejected brief" "$out"
echo "$out" | grep -q "^triage=agent-target" || fail "case 3 — triage value missing in parse" "$out"
ok "case 3 — /build's S2 reader accepts the brief"

# Case 4: task statement is in the body, not the frontmatter
grep -q "Rename misleading variable foo to bar in baz.sh" "$BRIEF" || fail "case 4 — task statement not in body"
ok "case 4 — task statement preserved in body"

# Case 5: overwrite is replacement, not append — re-running with the same
# issue produces a clean file with exactly one frontmatter block and no
# residue from the prior invocation
echo "Updated task statement" | bash "$WRITE" 299 >/dev/null
grep -q "Updated task statement" "$BRIEF" || fail "case 5 — overwrite did not take effect"
[ "$(grep -c '^---$' "$BRIEF")" = "2" ] || fail "case 5 — duplicate frontmatter after overwrite" "$(cat "$BRIEF")"
! grep -q "Rename misleading variable foo to bar in baz.sh" "$BRIEF" || fail "case 5 — original content not removed on overwrite"
ok "case 5 — overwrite produces a single clean brief"

# Case 6: missing issue arg → exits 1
if echo "x" | bash "$WRITE" 2>/dev/null; then
  fail "case 6 — missing issue arg" "expected exit 1, got exit 0"
fi
ok "case 6 — missing issue arg exits non-zero"

# Case 7: empty stdin → exits 1
if bash "$WRITE" 299 </dev/null 2>/dev/null; then
  fail "case 7 — empty stdin should exit non-zero"
fi
ok "case 7 — empty stdin rejected"

# Case 8: <issue> = 0 → exits 1 (read-s2-frontmatter.sh requires related-issue > 0)
if echo "x" | bash "$WRITE" 0 2>/dev/null; then
  fail "case 8 — issue=0 should exit non-zero"
fi
ok "case 8 — issue=0 rejected (downstream S2 gate requires > 0)"

# Case 9: <issue> with leading zero → exits 1 (consistency with case 8)
if echo "x" | bash "$WRITE" 042 2>/dev/null; then
  fail "case 9 — issue=042 (leading zero) should exit non-zero"
fi
ok "case 9 — leading-zero issue rejected"

echo "ALL PASS: write-agent-brief.sh"
