#!/usr/bin/env bash
# owner: roadmap
# Idempotently install the framework-fixed label vocabulary plus
# project-defined component labels. Run from /roadmap instantiate.
#
# Usage: install-labels.sh [--dry-run]
#
# Reads component_values (and audience_values if present) from
# roadmap.config.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

roadmap_require_gh

# Fetch all existing labels once so upsert_label can check membership without
# an O(N) round-trip per label. Limit 1000 covers repos with large label sets.
_EXISTING_LABELS=$(gh label list --limit 1000 --json name --jq '.[].name')
roadmap_label_exists() { echo "$_EXISTING_LABELS" | grep -Fxq "$1"; }

# label color palette (hex without leading #)
COLOR_TYPE="1d76db"
COLOR_HORIZON="0e8a16"
COLOR_COMPONENT="c5def5"
COLOR_AUDIENCE="d4c5f9"
COLOR_APPETITE="fbca04"
COLOR_STATE="b60205"
COLOR_SOFT="cccccc"

# (name, color, description) tuples
declare -a LABELS=(
  "type:epic|$COLOR_TYPE|Multi-session orchestrator; aggregates sub-issues toward an outcome"
  "type:feature|$COLOR_TYPE|New behaviour; routes to feature workflow"
  "type:bug|$COLOR_TYPE|Defect; routes to bug-fix workflow"
  "type:spike|$COLOR_TYPE|Investigation; routes to explore workflow"
  "type:refactor|$COLOR_TYPE|Restructure without changing behaviour"
  "type:docs|$COLOR_TYPE|Docs-only change"
  "type:chore|$COLOR_TYPE|Trivial maintenance; permitted without spec"
  "horizon:now|$COLOR_HORIZON|Ready to start; acceptance criteria + approach defined"
  "horizon:next|$COLOR_HORIZON|Shaped; problem + outcome + spec path defined"
  "horizon:later|$COLOR_HORIZON|Captured; awaiting triage and shaping"
  "appetite:small|$COLOR_APPETITE|1-3 sessions of effort (Epic only)"
  "appetite:medium|$COLOR_APPETITE|1-2 weeks of effort (Epic only)"
  "appetite:large|$COLOR_APPETITE|1+ month of effort (Epic only)"
  "blocked|$COLOR_STATE|Cannot proceed until external dependency resolves"
  "agent-ready|$COLOR_STATE|Issue prepared for autonomous AI agent pickup"
  "provisionally-resolved|$COLOR_SOFT|Maintain found partial evidence of resolution"
  "provisionally-stale|$COLOR_SOFT|Open >90d with no activity signal"
)

upsert_label() {
  local name="$1" color="$2" desc="$3"
  if roadmap_label_exists "$name"; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  [dry-run] would update: %s\n' "$name"
    else
      gh label edit "$name" --color "$color" --description "$desc" >/dev/null
      printf '  updated: %s\n' "$name"
    fi
  else
    if [ "$DRY_RUN" = "1" ]; then
      printf '  [dry-run] would create: %s\n' "$name"
    else
      gh label create "$name" --color "$color" --description "$desc" >/dev/null
      printf '  created: %s\n' "$name"
    fi
  fi
}

echo "Installing framework labels..."
for tuple in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<<"$tuple"
  upsert_label "$name" "$color" "$desc"
done

echo "Installing component labels (from roadmap.config.yaml)..."
while IFS= read -r val; do
  [ -z "$val" ] && continue
  upsert_label "component:$val" "$COLOR_COMPONENT" "Project-defined component"
done < <(roadmap_config_list component_values)

echo "Installing audience labels (optional)..."
while IFS= read -r val; do
  [ -z "$val" ] && continue
  upsert_label "audience:$val" "$COLOR_AUDIENCE" "Project-defined audience"
done < <(roadmap_config_list audience_values 2>/dev/null || true)

echo "Done."
