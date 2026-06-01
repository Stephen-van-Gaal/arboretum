#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-runtime-portability.sh - Verifies parser surfaces do not require PyYAML.
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

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

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }
  fail=1
}

run_no_yaml() {
  PYTHONPATH="$FIX/no-yaml" "$@"
}

mkdir -p "$FIX/project"
printf 'pipeline:\n  workflow: v2\n' > "$FIX/project/roadmap.config.yaml"
out=$(cd "$FIX/project" && run_no_yaml bash "$ROOT/scripts/read-pipeline-flag.sh" 2>"$FIX/rpf.err"); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "v2" ]; then
  pass "runtime: read-pipeline-flag works without PyYAML"
else
  fail_case "runtime: read-pipeline-flag" "rc=$rc out=$out err=$(cat "$FIX/rpf.err")"
fi

for test_script in \
  scripts/_smoke-test-read-pipeline-flag.sh \
  scripts/_smoke-test-contract-read-pipeline-flag.sh \
  scripts/_smoke-test-contract-yaml-lite.sh \
  scripts/_smoke-test-contract-read-s2-frontmatter.sh \
  scripts/_smoke-test-contract-read-test-config.sh \
  scripts/_smoke-test-contract-validate-design-spec.sh \
  scripts/_smoke-test-validate-cli-contract.sh \
  scripts/_smoke-test-contract-validate-cli-contract.sh \
  scripts/_smoke-test-contract-contract-coverage.sh
do
  out=$(cd "$ROOT" && run_no_yaml bash "$test_script" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    pass "runtime: $test_script"
  else
    fail_case "runtime: $test_script" "$out"
  fi
done

[ "$fail" = 0 ] && echo "runtime portability smoke: ALL PASS" || exit 1
