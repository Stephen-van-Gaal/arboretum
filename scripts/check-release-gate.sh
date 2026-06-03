#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# check-release-gate.sh — pull-request gate for release intent and release
# package materialization.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

BASE_REF="${BASE_REF:-origin/main}"

manifest_paths=(
  ".claude-plugin/plugin.json"
  ".claude-plugin/marketplace.json"
  ".codex-plugin/plugin.json"
)

manifest_count=0
for manifest_path in "${manifest_paths[@]}"; do
  [ -f "$manifest_path" ] && manifest_count=$((manifest_count + 1))
done

if [ "$manifest_count" -eq 0 ]; then
  echo "SKIP: plugin version manifests not found; release gate is not applicable in this root."
  exit 0
fi

if [ "$manifest_count" -ne "${#manifest_paths[@]}" ]; then
  {
    echo "FAIL: plugin version manifest set is incomplete."
    for manifest_path in "${manifest_paths[@]}"; do
      [ -f "$manifest_path" ] || echo "  missing: $manifest_path"
    done
  } >&2
  exit 1
fi

v_plugin="$(python3 -c 'import json; print(json.load(open(".claude-plugin/plugin.json"))["version"])')"
v_market="$(python3 -c 'import json; print(json.load(open(".claude-plugin/marketplace.json"))["version"])')"
v_market_plugin="$(python3 -c 'import json; print(json.load(open(".claude-plugin/marketplace.json"))["plugins"][0]["version"])')"
v_codex="$(python3 -c 'import json; print(json.load(open(".codex-plugin/plugin.json"))["version"])')"

if [ "$v_plugin" != "$v_market" ] || [ "$v_plugin" != "$v_market_plugin" ] || [ "$v_plugin" != "$v_codex" ]; then
  {
    echo "FAIL: plugin version occurrences disagree —"
    echo "  .claude-plugin/plugin.json          : $v_plugin"
    echo "  .claude-plugin/marketplace.json     : $v_market"
    echo "  .claude-plugin/marketplace.json [0] : $v_market_plugin"
    echo "  .codex-plugin/plugin.json           : $v_codex"
    echo "Fix: scripts/bump-version.sh <major|minor|patch> rewrites all four together."
  } >&2
  exit 1
fi

merge_base="$(git merge-base "$BASE_REF" HEAD)"
changed_paths="$(git diff --name-only "$merge_base" HEAD)"

manifest_changed=""
for manifest_path in "${manifest_paths[@]}"; do
  if printf '%s\n' "$changed_paths" | grep -Fxq "$manifest_path"; then
    manifest_changed=1
  fi
done

# Dev-only paths — mirror the exclude set in .github/workflows/sync-public.yml.
# docs/releases/ and CHANGELOG.md are deliberately NOT listed: they are
# customer-visible release package surfaces.
dev_only_regex='^(docs/specs/|docs/plans/|docs/superpowers/|docs/reviews/|docs/customer-validation/|docs/reference/|docs/ARCHITECTURE\.md$|docs/REGISTER\.md$|docs/contracts/prepare-customer-testbed\.cli-contract\.md$|customer-testbeds/|\.github/|\.agents/skills/|\.claude/skills/dev-|\.claude/skills/_archived/|\.claude/projects/|scripts/_archived/|scripts/prepare-customer-testbed\.sh$|scripts/_smoke-test-customer-testbed\.sh$|CLAUDE\.md$|README\.md$|\.gitmodules$|\.arboretum\.yml$|contracts\.yaml$)'
public_issue_form_regex='^\.github/ISSUE_TEMPLATE/arboretum-(problem|enhancement)\.md$'

shippable="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | grep -Ev "$dev_only_regex" || true)"
public_issue_forms="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | grep -E "$public_issue_form_regex" || true)"
shippable="$(printf '%s\n%s\n' "$shippable" "$public_issue_forms" | sed '/^$/d' | sort -u)"

base_version="$(git show "$merge_base:.claude-plugin/plugin.json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"

version_greater() {
  python3 - "$1" "$2" <<'PY'
import sys

def parse(v):
    return tuple(int(x) for x in v.split("."))

sys.exit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)
PY
}

if [ -n "$manifest_changed" ]; then
  if version_greater "$v_plugin" "$base_version"; then
    echo "OK: plugin manifests changed - version bumped $base_version -> $v_plugin."
    exit 0
  fi
  {
    echo "FAIL: plugin manifests changed but the plugin version was not incremented."
    echo "  base version : $base_version"
    echo "  this branch  : $v_plugin"
    echo "Fix: scripts/bump-version.sh <major|minor|patch>"
  } >&2
  exit 1
fi

if [ -z "$shippable" ]; then
  echo "OK: no shippable content changed - release intent not required."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
intent_output=""
intent_rc=0
if [ -n "${RELEASE_INTENT_BODY_FILE:-}" ]; then
  intent_output="$(bash "$SCRIPT_DIR/read-release-intent.sh" --body-file "$RELEASE_INTENT_BODY_FILE" 2>&1)" || intent_rc=$?
elif [ -n "${RELEASE_INTENT_EVENT:-}" ]; then
  intent_output="$(bash "$SCRIPT_DIR/read-release-intent.sh" --github-event "$RELEASE_INTENT_EVENT" 2>&1)" || intent_rc=$?
else
  {
    echo "SKIP: shippable content changed but release intent input not available before PR body."
    echo "      /pr must validate the Release Intent section before creating the PR;"
    echo "      PR CI must validate it from the GitHub event."
  }
  exit 0
fi

if [ "$intent_rc" -ne 0 ]; then
  {
    echo "FAIL: shippable content changed but release intent is missing or invalid."
    echo "$intent_output" | sed 's/^/  /'
    echo "  shippable paths changed:"
    echo "$shippable" | sed 's/^/    /'
  } >&2
  exit 1
fi

impact="$(printf '%s\n' "$intent_output" | awk -F= '$1 == "release-impact" { print $2; exit }')"
state="$(printf '%s\n' "$intent_output" | awk -F= '$1 == "release-state" { print $2; exit }')"

case "$impact" in
  patch|minor|major) ;;
  none)
    {
      echo "FAIL: shippable content changed but release-impact is none."
      echo "  shippable paths changed:"
      echo "$shippable" | sed 's/^/    /'
    } >&2
    exit 1
    ;;
  *)
    echo "FAIL: shippable content changed but release-impact is invalid: $impact" >&2
    exit 1
    ;;
esac

if [ "$state" != "pending" ]; then
  echo "FAIL: shippable content changed but release-state is not pending: $state" >&2
  exit 1
fi

echo "OK: shippable content changed - release intent $impact pending."
