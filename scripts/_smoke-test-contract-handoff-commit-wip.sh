#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
# Smoke test for docs/contracts/handoff-commit-wip.cli-contract.md.
# Exercises CLI-1..CLI-4 via four fixture scenarios (A-D) driving the
# script directly with a temp-dir project fixture. Picked up automatically
# by ci-checks.sh's === Smoke tests === loop.
#
# Push is exercised against a bare local remote inside the temp fixture —
# no network required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/handoff-commit-wip.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

# Identity flags reused across fixture inits — keeps CI runners without
# a global git config from failing at "Author identity unknown".
GIT_ID=(-c user.email=t@t -c user.name=t)

# ---------------------------------------------------------------------------
# Fixture setup
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT" 2>/dev/null' EXIT

# Bare remote — used as the push target so git push doesn't hit the network.
BARE_REMOTE="$TMPDIR_ROOT/remote.git"
git init -q --bare "$BARE_REMOTE"

# Project repo: feature branch + bare remote as 'origin'.
PROJECT="$TMPDIR_ROOT/project"
git "${GIT_ID[@]}" -C "$TMPDIR_ROOT" clone -q "$BARE_REMOTE" project
# Set identity *persistently* in the repo config — handoff-commit-wip.sh runs
# its own bare `git commit` (no -c flags), so it relies on ambient identity.
# CI runners have no global git identity, so without this the script's commit
# fails with "Author identity unknown" → exit 2 (green locally, red on CI).
( cd "$PROJECT" && git config user.email "t@t" && git config user.name "t" )
# Some git versions name the default branch 'master'; ensure we start clean.
( cd "$PROJECT" && git checkout -q -b feat/smoke-test 2>/dev/null || git checkout -q feat/smoke-test )
# Seed an initial commit so the branch exists on remote (push -u needs a ref).
( cd "$PROJECT" && git "${GIT_ID[@]}" commit -q --allow-empty -m "init" )
( cd "$PROJECT" && git push -q -u origin feat/smoke-test )

# Non-repo dir for CLI-4.
NON_REPO="$TMPDIR_ROOT/not-a-repo"
mkdir -p "$NON_REPO"

fail=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_pass() {
  local name="$1"; shift
  local rc stdout_file stderr_file
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  bash "$SCRIPT" "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name — expected exit 0, got $rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    fail=1
  else
    echo "PASS: $name (exit 0)"
  fi
  rm -f "$stdout_file" "$stderr_file"
}

run_fail() {
  local name="$1" expected_rc="$2" expected_msg="$3"; shift 3
  local rc stdout_file stderr_file
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  rc=0; bash "$SCRIPT" "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: $name — expected exit $expected_rc, got $rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    fail=1
  elif ! grep -q "$expected_msg" "$stderr_file"; then
    echo "FAIL: $name — expected stderr to contain '$expected_msg'; got: $(cat "$stderr_file")" >&2
    fail=1
  else
    echo "PASS: $name (exit $rc; stderr message present)"
  fi
  rm -f "$stdout_file" "$stderr_file"
}

# ---------------------------------------------------------------------------
# Scenario A — CLI-1: clean-tree no-op
# Working tree is clean after the init push above.
# ---------------------------------------------------------------------------
stdout_file=$(mktemp); stderr_file=$(mktemp)
bash "$SCRIPT" "$PROJECT" >"$stdout_file" 2>"$stderr_file"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: A: clean-tree no-op — expected exit 0, got $rc" >&2
  echo "  stdout: $(cat "$stdout_file")" >&2
  echo "  stderr: $(cat "$stderr_file")" >&2
  fail=1
elif ! grep -q "clean tree" "$stdout_file"; then
  echo "FAIL: A: clean-tree no-op — expected 'clean tree' in stdout; got: $(cat "$stdout_file")" >&2
  fail=1
else
  echo "PASS: A: clean-tree no-op (exit 0; 'clean tree' in stdout)"
fi
rm -f "$stdout_file" "$stderr_file"

# ---------------------------------------------------------------------------
# Scenario B — CLI-2: dirty-tree commit + push
# Create an untracked file so the tree is dirty, then run the script.
# Assert: exit 0; stdout is a short SHA; the new commit subject matches
# the documented format.
# ---------------------------------------------------------------------------
echo "wip content" > "$PROJECT/wip.txt"

stdout_file=$(mktemp); stderr_file=$(mktemp)
bash "$SCRIPT" "$PROJECT" >"$stdout_file" 2>"$stderr_file"
rc=$?
sha=$(cat "$stdout_file" | tr -d '[:space:]')
commit_msg=$( git -C "$PROJECT" log -1 --format='%s' 2>/dev/null || echo "" )
if [ "$rc" -ne 0 ]; then
  echo "FAIL: B: dirty-tree commit — expected exit 0, got $rc" >&2
  echo "  stdout: $(cat "$stdout_file")" >&2
  echo "  stderr: $(cat "$stderr_file")" >&2
  fail=1
elif ! echo "$sha" | grep -qE '^[0-9a-f]{4,12}$'; then
  echo "FAIL: B: dirty-tree commit — expected short SHA on stdout; got: '$sha'" >&2
  fail=1
elif ! echo "$commit_msg" | grep -qE '^wip: handoff [0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  echo "FAIL: B: dirty-tree commit — commit subject does not match expected format; got: '$commit_msg'" >&2
  fail=1
else
  echo "PASS: B: dirty-tree commit (exit 0; short SHA='$sha'; subject='$commit_msg')"
fi
rm -f "$stdout_file" "$stderr_file"

# ---------------------------------------------------------------------------
# Scenario C — CLI-3: protected-branch refusal (main)
# Create a fresh project on main; any tree state should be refused.
# ---------------------------------------------------------------------------
MAIN_PROJECT="$TMPDIR_ROOT/main-project"
git "${GIT_ID[@]}" -C "$TMPDIR_ROOT" clone -q "$BARE_REMOTE" main-project
( cd "$MAIN_PROJECT" && git "${GIT_ID[@]}" commit -q --allow-empty -m "init" )
# Ensure we're on a branch named 'main'.
( cd "$MAIN_PROJECT" && git checkout -q -b main 2>/dev/null || git checkout -q main )
# Add a dirty file so tree state is clear.
echo "dirty" > "$MAIN_PROJECT/dirty.txt"

run_fail "C: protected-branch refusal (main)" 1 "refusing to wip-commit on main" "$MAIN_PROJECT"

# ---------------------------------------------------------------------------
# Scenario D — CLI-4: non-repo failure
# Pass a plain directory with no .git; script must exit 1.
# ---------------------------------------------------------------------------
run_fail "D: non-repo failure" 1 "not a git repository" "$NON_REPO"

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
