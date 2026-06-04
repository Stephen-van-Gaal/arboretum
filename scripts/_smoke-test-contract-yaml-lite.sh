#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-yaml-lite.sh - Contract test for docs/contracts/yaml-lite.contract.md.
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/lib/yaml-lite.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }
  fail=1
}

assert_has_line() {
  case "
$1
" in
    *"
$2
"*) return 0 ;;
    *) return 1 ;;
  esac
}

cat > "$FIX/config.yaml" <<'YAML'
pipeline:
  workflow: "unified" # inline comment
quoted: "value # not comment"
plain: ok # stripped
apostrophe: WS4's CI integration
command: pytest -k "unit#fast" # trailing comment
YAML
out=$(bash "$HELPER" file "$FIX/config.yaml" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && assert_has_line "$out" "pipeline.workflow=unified" \
  && assert_has_line "$out" "quoted=value # not comment" \
  && assert_has_line "$out" "plain=ok" \
  && assert_has_line "$out" "apostrophe=WS4's CI integration" \
  && assert_has_line "$out" "command=pytest -k \"unit#fast\""; then
  pass "YL-1/YL-3/YL-9/YL-10: block mapping, quote stripping, comments, plain apostrophes, quoted hashes in plain scalars"
else
  fail_case "YL-1/YL-3/YL-9/YL-10" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

printf "pipeline: { workflow: 'unified' }\n" > "$FIX/flow.yaml"
out=$(bash "$HELPER" file "$FIX/flow.yaml" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "pipeline.workflow=unified" ]; then
  pass "YL-2: flow mapping"
else
  fail_case "YL-2" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

cat > "$FIX/doc.md" <<'MD'
---
owns:
  - scripts/read-pipeline-flag.sh
test-tiers:
  unit: yes
  contract: "n/a - no shared definition touched"
invokers:
  - type: skill
    name: design
  - type: script
    name: scripts/ci-checks.sh
flow-owns: [scripts/generate-coverage.sh, "scripts/foo # bar.sh"]
flow-invokers: [{type: hook}, {type: developer}]
---
# Body
MD
out=$(bash "$HELPER" frontmatter "$FIX/doc.md" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && assert_has_line "$out" "owns[]=scripts/read-pipeline-flag.sh" \
  && assert_has_line "$out" "test-tiers.unit=yes" \
  && assert_has_line "$out" "test-tiers.contract=n/a - no shared definition touched" \
  && assert_has_line "$out" "invokers[0].type=skill" \
  && assert_has_line "$out" "invokers[0].name=design" \
  && assert_has_line "$out" "invokers[1].type=script" \
  && assert_has_line "$out" "invokers[1].name=scripts/ci-checks.sh" \
  && assert_has_line "$out" "flow-owns[]=scripts/generate-coverage.sh" \
  && assert_has_line "$out" "flow-owns[]=scripts/foo # bar.sh" \
  && assert_has_line "$out" "flow-invokers[0].type=hook" \
  && assert_has_line "$out" "flow-invokers[1].type=developer"; then
  pass "YL-4/YL-5/YL-6/YL-11: frontmatter lists, mappings, list mappings, flow lists"
else
  fail_case "YL-4/YL-5/YL-6/YL-11" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

cat > "$FIX/bad-indent.yaml" <<'YAML'
pipeline: unified
  workflow: unified
YAML
out=$(bash "$HELPER" file "$FIX/bad-indent.yaml" 2>"$FIX/err"); rc=$?
if [ "$rc" -ne 0 ] && grep -q "yaml-lite:" "$FIX/err"; then
  pass "YL-12: indented key below scalar parent is rejected"
else
  fail_case "YL-12" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

printf "# no frontmatter\n" > "$FIX/no-frontmatter.md"
out=$(bash "$HELPER" frontmatter "$FIX/no-frontmatter.md" 2>"$FIX/err"); rc=$?
if [ "$rc" -ne 0 ] && grep -q "yaml-lite:" "$FIX/err"; then
  pass "YL-7: missing frontmatter fails with yaml-lite diagnostic"
else
  fail_case "YL-7" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

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
out=$(PYTHONPATH="$FIX/no-yaml" bash "$HELPER" file "$FIX/config.yaml" 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] && assert_has_line "$out" "pipeline.workflow=unified"; then
  pass "YL-8: no PyYAML import required"
else
  fail_case "YL-8" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "yaml-lite contract: ALL PASS" || exit 1
