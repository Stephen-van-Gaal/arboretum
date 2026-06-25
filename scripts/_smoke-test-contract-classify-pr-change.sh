#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-classify-pr-change.sh — Contract test for
# docs/contracts/classify-pr-change.contract.md. Asserts CPC-1..CPC-7
# against scripts/classify-pr-change.sh by feeding file lists on stdin
# (the --files-from - mode /land uses) and via a file. Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/classify-pr-change.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# classify a newline-separated list (passed as $1) via --files-from -
classify() { printf '%s' "$1" | bash "$PROBE" --files-from -; }

# CPC-1 — docs-only
out=$(classify $'README.md\ndocs/x.md\n'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "docs-config" ] && pass CPC-1 || fail_case CPC-1 "rc=$rc out=$out"

# CPC-2 — source file present → code
out=$(classify $'README.md\nsrc/foo.ts\n'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "code" ] && pass CPC-2 || fail_case CPC-2 "rc=$rc out=$out"

# CPC-3 — skill path → code (boundary)
out=$(classify $'docs/y.md\nskills/build/SKILL.md\n'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "code" ] && pass CPC-3 || fail_case CPC-3 "rc=$rc out=$out"

# CPC-4 — workflow path → code (boundary; .github/* and *.yml otherwise docs-config)
out=$(classify $'.github/workflows/ci.yml\n'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "code" ] && pass CPC-4 || fail_case CPC-4 "rc=$rc out=$out"

# CPC-5 — config-only → docs-config
out=$(classify $'contracts.yaml\n.gitignore\npackage.json\n'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "docs-config" ] && pass CPC-5 || fail_case CPC-5 "rc=$rc out=$out"

# CPC-6 — empty stdin → docs-config (safe default)
out=$(printf '' | bash "$PROBE" --files-from -); rc=$?
[ "$rc" = 0 ] && [ "$out" = "docs-config" ] && pass CPC-6 || fail_case CPC-6 "rc=$rc out=$out"

# CPC-7 — --files-from <file> matches stdin behaviour
printf 'docs/a.md\nsrc/b.py\n' > "$FIX/files.txt"
out=$(bash "$PROBE" --files-from "$FIX/files.txt"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "code" ] && pass CPC-7 || fail_case CPC-7 "rc=$rc out=$out"

[ "$fail" = 0 ] && echo "classify-pr-change contract: ALL PASS" || exit 1
