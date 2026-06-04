#!/usr/bin/env bash
# owner: workflow-unification
# read-patch-lane-config.sh — Read patch-lane workflow configuration.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "read-patch-lane-config.sh requires bash" >&2; exit 1; }

CONFIG="${1:-.arboretum.yml}"
[ -f "$CONFIG" ] || { echo "read-patch-lane-config.sh: config not found: $CONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-patch-lane-config.sh: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-patch-lane-config.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

BUDGET=$(printf '%s\n' "$PARSED" | awk -F= '$1 == "patch_lane.investigation_budget_minutes" { print substr($0, index($0, "=") + 1); exit }')
[ -n "$BUDGET" ] || BUDGET=15

case "$BUDGET" in
  ''|*[!0-9]*|0|0[0-9]*)
    echo "read-patch-lane-config.sh: patch_lane.investigation_budget_minutes must be a positive integer, got: $BUDGET" >&2
    exit 1
    ;;
esac

printf 'investigation_budget_minutes=%s\n' "$BUDGET"
