#!/usr/bin/env bash
# owner: document-taxonomy
# ci-tier: balanced
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
V="$ROOT/scripts/validate-group-membership.sh"
F="$ROOT/scripts/_fixtures/group-membership"
fail=0
expect() { # <fixture> <expected-exit>
  local fx="$1" exp="$2" rc=0
  bash "$V" "$F/$fx" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$exp" ] || { echo "FAIL: $fx expected exit $exp got $rc"; fail=1; }
}
expect valid 0
expect orphan-contains 1
expect missing-parent 1
expect dangling-parent 1
# a list-valued parent is a dual-parent violation — strict ownership tree (#742 D1)
expect dual-parent 1
# an empty-list parent (parent: []) is also a list form — yaml-lite drops it, raw check catches it (Codex P2)
expect empty-list-parent 1
expect glue-ok 0
expect glue-bad 1
# block-list frontmatter parsing (yaml-lite; Copilot #1)
expect block-valid 0
# SKILL.md umbrella-dispatcher glue, forward + reverse (D7; Copilot #2/#3)
expect glue-skill-ok 0
expect glue-skill-bad 1

# the real (group-free) repo must pass vacuously — no false positives (D4)
rc=0; bash "$V" "$ROOT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: real repo should pass vacuously, got $rc"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: group-membership" || exit 1
