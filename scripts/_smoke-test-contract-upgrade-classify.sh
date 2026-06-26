#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-contract-upgrade-classify.sh — Contract test for
# docs/contracts/upgrade-classify.contract.md. Asserts UC-1..UC-6
# against scripts/lib/upgrade-classify.sh.
#
# upgrade-classify.sh is a pure sourceable lib exposing classify_file.
# We source it in this process and call classify_file with crafted SHA
# placeholders to drive each branch, asserting the echoed action token.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/upgrade-classify.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

# shellcheck source=scripts/lib/upgrade-classify.sh
source "$LIB"

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  expected=$2" >&2; fail=1; }

# expect <id> <expected-token> BASE OURS THEIRS IN_PLUGIN IN_TREE
expect() {
  local id="$1" want="$2"; shift 2
  local got; got="$(classify_file "$@")"
  [ "$got" = "$want" ] && pass "$id ($want)" || fail_case "$id" "$want, got=$got args=[$*]"
}

# Placeholder SHAs — only equality relationships matter.
A=aaaa; B=bbbb; C=cccc

# UC-1 — add: empty base, plugin-only, never tracked
expect UC-1 add        "" "" "$A" yes no
# UC-2 — keep-local: tracked, plugin == base, user deleted in tree
expect UC-2 keep-local "$A" "" "$A" yes no
# UC-3 — conflict: tracked, deleted in tree, plugin moved
expect UC-3 conflict   "$A" "" "$B" yes no
# UC-4 — report-removed: tracked, vanished from plugin
expect UC-4 report-removed "$A" "$A" "" no yes
# UC-5 — unchanged: untracked user-owned, plugin-absent
expect UC-5 unchanged  "" "$A" "" no yes
# UC-6 — both-present matrix (plugin-wins #394: a divergent local copy is
# overwrite-local, not keep-local/conflict — those are deletion-only).
expect "UC-6 unchanged"       unchanged       "$A" "$A" "$A" yes yes
expect "UC-6 overwrite-safe"  overwrite-safe  "$A" "$A" "$B" yes yes
expect "UC-6 overwrite-local-idle" overwrite-local "$A" "$B" "$A" yes yes
expect "UC-6 converged"       converged       "$A" "$B" "$B" yes yes
expect "UC-6 overwrite-local-diverged" overwrite-local "$A" "$B" "$C" yes yes

[ "$fail" = 0 ] && echo "upgrade-classify contract: ALL PASS" || exit 1
