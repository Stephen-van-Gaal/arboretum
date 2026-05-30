#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-read-pipeline-flag.sh — Contract test for
# docs/contracts/read-pipeline-flag.contract.md. Asserts RPF-1..RPF-7
# against scripts/read-pipeline-flag.sh using a mktemp CWD fixture
# carrying a roadmap.config.yaml. Picked up automatically by
# ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/read-pipeline-flag.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

run() { ( cd "$FIX" && bash "$PROBE" ) 2>"$FIX/.err"; }   # echoes stdout, sets $? ; stderr in .err

# RPF-1
printf 'pipeline:\n  workflow: v2\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = v2 ] && pass RPF-1 || fail_case RPF-1 "rc=$rc out=$out"
# RPF-2
printf 'pipeline:\n  workflow: v1\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = v1 ] && pass RPF-2 || fail_case RPF-2 "rc=$rc out=$out"
# RPF-3 absent pipeline block
printf 'other: true\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = v1 ] && pass RPF-3 || fail_case RPF-3 "rc=$rc out=$out"
# RPF-4 absent workflow key
printf 'pipeline:\n  other: 1\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = v1 ] && pass RPF-4 || fail_case RPF-4 "rc=$rc out=$out"
# RPF-5 out-of-set
printf 'pipeline:\n  workflow: v3\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && pass RPF-5 || fail_case RPF-5 "rc=$rc out=$out"
# RPF-6 missing config
rm -f "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && pass RPF-6 || fail_case RPF-6 "rc=$rc out=$out"
# RPF-7 read-only
printf 'pipeline:\n  workflow: v2\n' > "$FIX/roadmap.config.yaml"
before=$(shasum "$FIX/roadmap.config.yaml" | cut -d' ' -f1); run >/dev/null
after=$(shasum "$FIX/roadmap.config.yaml" | cut -d' ' -f1)
[ "$before" = "$after" ] && pass RPF-7 || fail_case RPF-7 "config mutated"

[ "$fail" = 0 ] && echo "read-pipeline-flag contract: ALL PASS" || exit 1
