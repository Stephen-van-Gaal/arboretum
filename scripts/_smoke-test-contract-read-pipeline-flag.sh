#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-read-pipeline-flag.sh — Contract test for
# docs/contracts/read-pipeline-flag.contract.md. Asserts RPF-1..RPF-10
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

# RPF-1 explicit current general-release
printf 'pipeline:\n  workflow: unified\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = unified ] && pass RPF-1 || fail_case RPF-1 "rc=$rc out=$out"
# RPF-2 absent pipeline block defaults to current general-release
printf 'other: true\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = unified ] && pass RPF-2 || fail_case RPF-2 "rc=$rc out=$out"
# RPF-3 absent workflow key defaults to current general-release
printf 'pipeline:\n  other: 1\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 0 ] && [ "$out" = unified ] && pass RPF-3 || fail_case RPF-3 "rc=$rc out=$out"
# RPF-4 retired v1 fails closed
printf 'pipeline:\n  workflow: v1\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q "retired" "$FIX/.err" && pass RPF-4 \
  || fail_case RPF-4 "rc=$rc out=$out err=$(cat "$FIX/.err")"
# RPF-5 retired v2 fails closed
printf 'pipeline:\n  workflow: v2\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q "retired" "$FIX/.err" && pass RPF-5 \
  || fail_case RPF-5 "rc=$rc out=$out err=$(cat "$FIX/.err")"
# RPF-6 unknown values fail closed
printf 'pipeline:\n  workflow: experimental\n' > "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q "unknown pipeline.workflow value" "$FIX/.err" && pass RPF-6 \
  || fail_case RPF-6 "rc=$rc out=$out err=$(cat "$FIX/.err")"
# RPF-7 missing config
rm -f "$FIX/roadmap.config.yaml"
out=$(run); rc=$?
[ "$rc" = 1 ] && pass RPF-7 || fail_case RPF-7 "rc=$rc out=$out"
# RPF-8 read-only
printf 'pipeline:\n  workflow: unified\n' > "$FIX/roadmap.config.yaml"
before=$(shasum "$FIX/roadmap.config.yaml" | cut -d' ' -f1); run >/dev/null
after=$(shasum "$FIX/roadmap.config.yaml" | cut -d' ' -f1)
[ "$before" = "$after" ] && pass RPF-8 || fail_case RPF-8 "config mutated"

# RPF-9 no PyYAML dependency
mkdir -p "$FIX/no-yaml"
cat > "$FIX/no-yaml/sitecustomize.py" <<'PY'
import builtins
_orig_import = builtins.__import__
def guarded_import(name, globals=None, locals=None, fromlist=(), level=0):
    if name == "yaml" or name.startswith("yaml."):
        raise ModuleNotFoundError("No module named 'yaml'")
    return _orig_import(name, globals, locals, fromlist, level)
builtins.__import__ = guarded_import
PY
printf 'pipeline:\n  workflow: unified\n' > "$FIX/roadmap.config.yaml"
out=$(PYTHONPATH="$FIX/no-yaml" run); rc=$?
[ "$rc" = 0 ] && [ "$out" = unified ] && pass RPF-9 || fail_case RPF-9 "rc=$rc out=$out err=$(cat "$FIX/.err")"

# RPF-10 missing yaml-lite helper reports a clear dependency diagnostic.
MISSING_HELPER="$FIX/missing-helper"
mkdir -p "$MISSING_HELPER/scripts"
cp "$PROBE" "$MISSING_HELPER/scripts/read-pipeline-flag.sh"
printf 'pipeline:\n  workflow: unified\n' > "$MISSING_HELPER/roadmap.config.yaml"
out=$(cd "$MISSING_HELPER" && bash scripts/read-pipeline-flag.sh 2>"$FIX/.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q "yaml-lite helper not found" "$FIX/.err" && pass RPF-10 \
  || fail_case RPF-10 "rc=$rc out=$out err=$(cat "$FIX/.err")"

[ "$fail" = 0 ] && echo "read-pipeline-flag contract: ALL PASS" || exit 1
