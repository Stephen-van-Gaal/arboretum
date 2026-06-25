#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# Idempotent label installer for /roadmap.
#
# Installs the framework-fixed label vocabulary (type:*, horizon:*, appetite:*,
# state markers) and the project-defined component labels from roadmap.config.yaml.
#
# Flags:
#   --dry-run       print TSV (name<TAB>color<TAB>description); no tracker calls
#   --config <path> path to roadmap.config.yaml (default: ./roadmap.config.yaml)
#   --no-components install only framework-fixed labels; skip components

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: requires bash. Run: bash $0" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

dry_run=false
no_components=false
config="roadmap.config.yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       dry_run=true; shift ;;
    --config)        config="$2"; shift 2 ;;
    --no-components) no_components=true; shift ;;
    -h|--help)
      sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Build label list as TSV: name<TAB>color<TAB>description
labels=()
add() { labels+=("$(printf '%s\t%s\t%s' "$1" "$2" "$3")"); }

# Type labels (framework-fixed; 1:1 workflow mapping per spec §2e)
add "type:epic"     "8a2be2" "Multi-session arc orchestrator (no workflow; container)"
add "type:feature"  "a2eeef" "New feature work (workflow: feature)"
add "type:bug"      "d73a4a" "Bug fix (workflow: bug-fix)"
add "type:spike"    "fbca04" "Investigation / spike (workflow: explore)"
add "type:refactor" "c5def5" "Refactor without behaviour change (workflow: refactor)"
add "type:docs"     "0075ca" "Documentation (workflow: documentation)"
add "type:chore"    "ededed" "Trivial / chore — no spec required"

# Horizon labels (framework-fixed)
add "horizon:now"   "0e8a16" "In flight or next-up — fully shaped, ready to start"
add "horizon:next"  "fbca04" "Committed to current outcome — shaped, not yet started"
add "horizon:later" "c5def5" "Captured but not yet committed — minimal detail OK"

# Appetite labels (Epic-only; framework-fixed)
add "appetite:small"  "fbca04" "1-3 sessions of effort (Epic only)"
add "appetite:medium" "fbca04" "1-2 weeks of effort (Epic only)"
add "appetite:large"  "fbca04" "1+ month of effort (Epic only)"

# State markers (universal boolean flags)
add "blocked"                 "b60205" "Cannot proceed until dependency resolves"
add "agent-ready"             "1d76db" "Specced AND timing-ready for autonomous AI agent pickup"
add "agent-prep:in-progress"  "5319e7" "Spec-quality verified but not yet timing-ready"
add "provisionally-resolved"  "fbca04" "Soft-state: PR evidence partially supports closing — review"
add "provisionally-stale"     "fbca04" "Soft-state: open >90d, no activity signal — review or close"

# Pipeline stage labels (exclusive per issue; set by log-stage.sh — #570)
add "stage:start"             "0e8a16" "Pipeline stage: /start"
add "stage:design"            "0e8a16" "Pipeline stage: /design"
add "stage:build"             "0e8a16" "Pipeline stage: /build"
add "stage:finish"            "0e8a16" "Pipeline stage: /finish"
add "stage:security-review"   "0e8a16" "Pipeline stage: /security-review"
add "stage:pr"                "0e8a16" "Pipeline stage: /pr"
add "stage:land"              "0e8a16" "Pipeline stage: /land"
add "stage:cleanup"           "0e8a16" "Pipeline stage: /cleanup"
add "stage:reflect"           "0e8a16" "Pipeline stage: /reflect"
add "stage:handoff"           "0e8a16" "Pipeline stage: /handoff"

# Component labels — read from config if present and not --no-components
if ! $no_components; then
  if [ -f "$config" ]; then
    # Extract component_values from YAML using grep+sed (avoid yq dep).
    # Robust enough for the simple list shape we use:
    #   component_values:
    #     - foo
    #     - bar
    components="$(awk '
      /^component_values:[[:space:]]*$/ { in_block=1; next }
      in_block && /^[[:space:]]*-[[:space:]]*/ {
        sub(/^[[:space:]]*-[[:space:]]*/, "");
        sub(/[[:space:]]*$/, "");
        if (NF) print
        next
      }
      in_block && /^[^[:space:]]/ { in_block=0 }
    ' "$config")"

    if [ -z "$components" ]; then
      echo "Warning: $config exists but has no component_values:; skipping component labels" >&2
    else
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        add "component:$c" "ededed" "Component (project-defined): $c"
      done <<< "$components"
    fi
  else
    echo "Note: $config not found; skipping component labels (run /roadmap instantiate to create config)" >&2
  fi
fi

# Audience labels — same pattern as components, optional axis
if ! $no_components && [ -f "$config" ]; then
  audiences="$(awk '
    /^audience_values:[[:space:]]*$/ { in_block=1; next }
    in_block && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "");
      sub(/[[:space:]]*$/, "");
      if (NF) print
      next
    }
    in_block && /^[^[:space:]]/ { in_block=0 }
  ' "$config")"

  if [ -n "$audiences" ]; then
    while IFS= read -r a; do
      [ -z "$a" ] && continue
      add "audience:$a" "fef2c0" "Audience (project-defined): $a"
    done <<< "$audiences"
  fi
fi

if $dry_run; then
  printf '%s\n' "${labels[@]}"
  exit 0
fi

# Live mode
roadmap_require_backend || exit 1

existing="$(roadmap_tracker_label_list --limit 200 --json name --jq '.[].name')"

created=0
skipped=0
failed=0
for entry in "${labels[@]}"; do
  IFS=$'\t' read -r name color description <<< "$entry"
  if printf '%s\n' "$existing" | grep -Fxq "$name"; then
    echo "skip:   $name"
    skipped=$((skipped + 1))
  else
    if roadmap_tracker_label_create "$name" --color "$color" --description "$description" >/dev/null 2>&1; then
      echo "create: $name"
      created=$((created + 1))
    else
      echo "FAIL:   $name (tracker label create failed)" >&2
      failed=$((failed + 1))
    fi
  fi
done

echo
echo "Summary: created=$created  skipped=$skipped  failed=$failed"
[ "$failed" -eq 0 ] || exit 1
