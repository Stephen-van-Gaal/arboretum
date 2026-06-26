#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$ROOT/docs/contracts/cleanup-merged-session.cli-contract.md"
HELPER="$ROOT/scripts/cleanup-merged-session.sh"
HELP_OUT="${TMPDIR:-/tmp}/cleanup-helper-help.$$"
fail=0

pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$CONTRACT" ] && pass "contract exists" || fail_case "contract missing"
grep -q 'script: scripts/cleanup-merged-session.sh' "$CONTRACT" && pass "script frontmatter documented" || fail_case "script frontmatter missing"
grep -q 'cleanup=skipped reason=<reason>' "$CONTRACT" && pass "status token documented" || fail_case "status token missing"
grep -q 'git branch -D' "$CONTRACT" && pass "force delete exemption documented" || fail_case "force delete exemption missing"
grep -q 'never delete remote branches' "$CONTRACT" && pass "remote deletion forbidden" || fail_case "remote deletion boundary missing"
grep -q 'worktree-branch-mismatch' "$CONTRACT" && pass "worktree branch mismatch refusal documented" || fail_case "worktree branch mismatch refusal missing"
grep -q 'remote default target branch' "$CONTRACT" && pass "default target proof documented" || fail_case "default target proof missing"
grep -q 'worktree=kept reason=remove-failed' "$CONTRACT" && pass "remove failure token documented" || fail_case "remove failure token missing"
grep -q 'session=terminal reason=active-worktree-removed action=end-or-reopen-session' "$CONTRACT" && pass "active worktree terminal token documented" || fail_case "active worktree terminal token missing"

if [ -f "$HELPER" ]; then
  bash "$HELPER" --help >"$HELP_OUT" 2>&1
  rc=$?
  [ "$rc" = 0 ] && grep -q 'cleanup-merged-session' "$HELP_OUT" && pass "helper help" || fail_case "helper help invalid"
else
  fail_case "helper missing"
fi

rm -f "$HELP_OUT"
[ "$fail" = 0 ] || exit 1
