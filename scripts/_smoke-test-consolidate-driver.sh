#!/usr/bin/env bash
# owner: consolidate-spec
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-consolidate-driver.sh — structural guard for the /consolidate
# conductor/driver conversion + role-separated Step 6 (#666, #870).
#
# skills/consolidate/SKILL.md is prose, not executable code, so this asserts the
# load-bearing references are present: the read-only driver dispatch, the
# terminal-write principle, and the role-separated Step 6 using the new
# health-check flags. Guards against silently reverting to the old unconditional
# `health-check.sh --reconcile` stale-flip.
#
# Usage: bash scripts/_smoke-test-consolidate-driver.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -uo pipefail
[ -z "${BASH_VERSION:-}" ] && { echo "Run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$ROOT/skills/consolidate/SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found" >&2; exit 1; }

fail=0
check() {  # check <regex> <failure message>  — `--` lets leading-dash patterns match
  grep -qiE -- "$1" "$SKILL" || { echo "FAIL: $2" >&2; fail=1; }
}

check 'consolidate driver'        "SKILL.md does not describe a consolidate driver"
check 'read-only'                 "driver is not declared read-only"
check 'driver owns orchestration' "missing the terminal-write principle (driver owns orchestration; main owns the terminal action)"
check '\-\-reconcile \-\-dry-run' "Step 6 does not use the dry-run report mode"
check '\-\-keep-active'           "Step 6 does not apply role-separated keep-active flip"
check 'role'                      "Step 6 does not reference the reconciler/surveillance role separation"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else exit 1; fi
