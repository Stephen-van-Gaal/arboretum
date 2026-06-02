#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# check-version-bump.sh — pull-request gate. Two assertions:
#   1. The four plugin-version occurrences are mutually equal.
#   2. If the diff against the merge-base touches shippable content, the
#      plugin version was incremented.
#
# Base ref via BASE_REF env (CI sets it); defaults to origin/main.
# Honours REPO_ROOT (env) for testability.

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
  echo "SKIP: plugin version manifests not found; version-bump gate is not applicable in this root."
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

# --- Assertion 1: the four version occurrences agree ---
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

# --- Did the PR change shippable content? ---
merge_base="$(git merge-base "$BASE_REF" HEAD)"

# Dev-only paths — mirror the exclude set in .github/workflows/sync-public.yml.
# A diff confined to these does not reach the public repo and needs no bump.
# CLAUDE.public.md / README.public.md are deliberately NOT listed: sync-public.yml
# copies them into the published CLAUDE.md / README.md, so they are shippable.
# Most of .github/ stays dev-only, but sync-public.yml explicitly copies the
# Arboretum report issue-form mirrors into the public repo; add those back to
# shippable below after the broad .github/ denylist.
# File patterns are $-anchored so e.g. CLAUDE.md does not also exempt a
# stray CLAUDE.md.bak; directory patterns end in / by design.
dev_only_regex='^(docs/specs/|docs/plans/|docs/superpowers/|docs/reviews/|docs/reference/|docs/ARCHITECTURE\.md$|docs/REGISTER\.md$|\.github/|\.agents/skills/|\.claude/skills/dev-|\.claude/skills/_archived/|\.claude/projects/|scripts/_archived/|CLAUDE\.md$|README\.md$|\.gitmodules$|\.arboretum\.yml$|contracts\.yaml$)'
public_issue_form_regex='^\.github/ISSUE_TEMPLATE/arboretum-(problem|enhancement)\.md$'

changed_paths="$(git diff --name-only "$merge_base" HEAD)"
shippable="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | grep -Ev "$dev_only_regex" || true)"
public_issue_forms="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | grep -E "$public_issue_form_regex" || true)"
shippable="$(printf '%s\n%s\n' "$shippable" "$public_issue_forms" | sed '/^$/d' | sort -u)"

if [ -z "$shippable" ]; then
  echo "OK: no shippable content changed — version bump not required (version $v_plugin)."
  exit 0
fi

# --- Assertion 2: shippable content changed, so the version must increase ---
base_version="$(git show "$merge_base:.claude-plugin/plugin.json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"

if python3 -c 'import sys
def parse(v): return tuple(int(x) for x in v.split("."))
sys.exit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)' "$v_plugin" "$base_version"; then
  echo "OK: shippable content changed; version bumped $base_version -> $v_plugin."
  exit 0
fi

{
  echo "FAIL: shippable content changed but the plugin version was not incremented."
  echo "  base version : $base_version"
  echo "  this branch  : $v_plugin"
  echo "  shippable paths changed:"
  echo "$shippable" | sed 's/^/    /'
  echo "Fix: scripts/bump-version.sh <major|minor|patch>"
} >&2
exit 1
