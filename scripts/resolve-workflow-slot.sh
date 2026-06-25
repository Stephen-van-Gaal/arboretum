#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# resolve-workflow-slot.sh - Resolve an Arboretum workflow skill slot.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: bash scripts/resolve-workflow-slot.sh <slot> [--config <path>] [--repo-root <path>]

Resolves a known Arboretum workflow slot to a slash-style skill target.
USAGE
}

fail() {
  echo "resolve-workflow-slot: $1" >&2
  exit "${2:-1}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || fail "yaml-lite helper not found at $YAML_LITE" 2

slot=""
config_path=""
repo_root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --config)
      [ "$#" -ge 2 ] || fail "--config requires a path" 2
      config_path="$2"
      shift 2
      ;;
    --repo-root)
      [ "$#" -ge 2 ] || fail "--repo-root requires a path" 2
      repo_root="$2"
      shift 2
      ;;
    --*)
      fail "unknown option: $1" 2
      ;;
    *)
      if [ -n "$slot" ]; then
        fail "unexpected extra argument: $1" 2
      fi
      slot="$1"
      shift
      ;;
  esac
done

[ -n "$slot" ] || { usage; exit 2; }

case "$slot" in
  ship-tail.reflect) default_target="/reflect" ;;
  *) fail "unknown workflow skill slot: $slot" ;;
esac

if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$repo_root" ] || fail "repo root not found: $repo_root" 2
repo_root="$(cd "$repo_root" && pwd -P)"

target="$default_target"
source_label="default"

if [ -z "$config_path" ]; then
  config_path="$repo_root/.arboretum.yml"
  config_required=false
else
  config_required=true
fi

if [ -f "$config_path" ]; then
  config_key="workflow.skill_slots.$slot"
  parsed_config="$(bash "$YAML_LITE" file "$config_path")" \
    || fail "invalid YAML-lite config: $config_path"
  if awk -v slot="$slot" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_comment(s) { sub(/[[:space:]]*#.*/, "", s); return s }
    function indent(s) { match(s, /[^ ]/); return RSTART ? RSTART - 1 : length(s) }
    {
      line = strip_comment($0)
      if (trim(line) == "") next
      current_indent = indent(line)
      text = trim(line)
      if (current_indent <= 0) { in_workflow = 0; in_slots = 0 }
      if (current_indent <= 2) { in_slots = 0 }
      if (current_indent == 0 && text == "workflow:") { in_workflow = 1; next }
      if (in_workflow && current_indent == 2 && text == "skill_slots:") { in_slots = 1; next }
      if (in_slots && current_indent == 4 && text == slot ":") { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$config_path"; then
    target=""
    source_label=".arboretum.yml"
  elif configured_target="$(
    printf '%s\n' "$parsed_config" \
      | awk -F= -v key="$config_key" '
        $1 == key {
          found = 1
          print substr($0, index($0, "=") + 1)
          exit
        }
        END { exit found ? 0 : 1 }
      '
  )"; then
    target="$configured_target"
    source_label=".arboretum.yml"
  fi
elif [ "$config_required" = true ]; then
  fail "config not found: $config_path" 2
fi

if ! [[ "$target" =~ ^/[a-z][a-z0-9-]*$ ]]; then
  fail "workflow skill slot $slot target must be slash-style: $target"
fi

skill_name="${target#/}"
candidates=(
  "$repo_root/skills/$skill_name/SKILL.md"
  "$repo_root/.claude/skills/$skill_name/SKILL.md"
)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  candidates+=("$CLAUDE_PLUGIN_ROOT/skills/$skill_name/SKILL.md")
fi

skill_path=""
for candidate in "${candidates[@]}"; do
  if [ -f "$candidate" ]; then
    skill_path="$candidate"
    break
  fi
done

if [ -z "$skill_path" ]; then
  {
    echo "resolve-workflow-slot: skill target not found: $target"
    echo "resolve-workflow-slot: searched:"
    for candidate in "${candidates[@]}"; do
      echo "  - $candidate"
    done
  } >&2
  exit 1
fi

parsed_skill="$(bash "$YAML_LITE" frontmatter "$skill_path")" \
  || fail "invalid skill frontmatter for $target: $skill_path"

if ! printf '%s\n' "$parsed_skill" \
  | awk -F= -v slot="$slot" '$1 == "implements-slots[]" && substr($0, index($0, "=") + 1) == slot { found = 1 } END { exit found ? 0 : 1 }'
then
  fail "skill target $target missing implements-slots entry for $slot"
fi

case "$skill_path" in
  "$repo_root"/*) display_skill_path="${skill_path#"$repo_root"/}" ;;
  *) display_skill_path="$skill_path" ;;
esac

printf 'slot=%s\n' "$slot"
printf 'target=%s\n' "$target"
printf 'source=%s\n' "$source_label"
printf 'status=resolved\n'
printf 'skill_path=%s\n' "$display_skill_path"
