#!/usr/bin/env bash
# owner: workflow-unification
# read-pipeline-flag.sh — Print the active pipeline.workflow value (v1 or v2).
# Reads ./roadmap.config.yaml in the current working directory.
# Exits 0 with "v1" if the pipeline block or workflow key is absent.
# Exits 1 with diagnostic if the config file is missing, YAML is invalid,
# or the value is not v1/v2.
#
# Uses scripts/lib/yaml-lite.sh so workflow entrypoints run from a bare
# checkout without requiring PyYAML, yq, jq, or package installation.
set -euo pipefail

CONFIG="roadmap.config.yaml"
if [ ! -f "$CONFIG" ]; then
  echo "read-pipeline-flag.sh: $CONFIG not found in $(pwd)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || {
  echo "read-pipeline-flag.sh: yaml-lite helper not found at $YAML_LITE" >&2
  exit 1
}

if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-pipeline-flag.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

VALUE=$(printf '%s\n' "$PARSED" | awk -F= '$1 == "pipeline.workflow" { print substr($0, index($0, "=") + 1); exit }')

# Default to v1 when the block or key is absent - preserves current behaviour
# for any project that hasn't opted in.
if [ -z "$VALUE" ]; then
  echo "v1"
  exit 0
fi

case "$VALUE" in
  v1|v2) echo "$VALUE" ;;
  *)
    echo "read-pipeline-flag.sh: invalid pipeline.workflow value: $VALUE (expected v1 or v2)" >&2
    exit 1
    ;;
esac
