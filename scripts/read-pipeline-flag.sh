#!/usr/bin/env bash
# owner: workflow-unification
# read-pipeline-flag.sh — Print the active named pipeline.workflow value.
# Reads ./roadmap.config.yaml in the current working directory.
# Exits 0 with "unified" if the pipeline block or workflow key is absent.
# Exits 1 with diagnostic if the config file is missing, YAML is invalid,
# or the value is retired or unsupported.
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

CURRENT_GENERAL_RELEASE="unified"
SUPPORTED_PIPELINES="unified"

# Default to the current general-release pipeline when the block or key is
# absent. The config key is a feature flag, not a required customer setting.
if [ -z "$VALUE" ]; then
  echo "$CURRENT_GENERAL_RELEASE"
  exit 0
fi

case "$VALUE" in
  unified)
    echo "$VALUE"
    ;;
  v1|v2)
    echo "read-pipeline-flag.sh: retired pipeline.workflow value: $VALUE; remove pipeline.workflow or set it to $CURRENT_GENERAL_RELEASE" >&2
    exit 1
    ;;
  *)
    echo "read-pipeline-flag.sh: unknown pipeline.workflow value: $VALUE (supported: $SUPPORTED_PIPELINES)" >&2
    exit 1
    ;;
esac
