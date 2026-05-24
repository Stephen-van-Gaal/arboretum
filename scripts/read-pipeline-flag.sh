#!/usr/bin/env bash
# owner: workflow-unification
# read-pipeline-flag.sh — Print the active pipeline.workflow value (v1 or v2).
# Reads ./roadmap.config.yaml in the current working directory.
# Exits 0 with "v1" if the pipeline block or workflow key is absent.
# Exits 1 with diagnostic if the config file is missing, YAML is invalid,
# or the value is not v1/v2.
#
# Uses python3 + PyYAML (already a project dep — see check-version-bump.sh)
# rather than awk so that all YAML-legal forms — block or flow style,
# quoted or unquoted values, inline comments, nested structures — are
# handled by a real parser instead of by a single-key regex extractor.
set -euo pipefail

CONFIG="roadmap.config.yaml"
if [ ! -f "$CONFIG" ]; then
  echo "read-pipeline-flag.sh: $CONFIG not found in $(pwd)" >&2
  exit 1
fi

VALUE=$(python3 - "$CONFIG" <<'PY'
import sys
import yaml

config_path = sys.argv[1]
try:
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
except yaml.YAMLError as e:
    print(f"read-pipeline-flag.sh: invalid YAML in {config_path}: {e}", file=sys.stderr)
    sys.exit(1)

pipeline = cfg.get("pipeline")
if not isinstance(pipeline, dict):
    # No pipeline block, or pipeline is not a mapping → back-compat default
    print("")
    sys.exit(0)

value = pipeline.get("workflow")
if value is None:
    print("")
    sys.exit(0)

# yaml.safe_load already strips quotes and resolves comments; coerce to
# str so a YAML int/bool surfaces as a string the case enum can reject.
print(str(value))
PY
)

# Default to v1 when the block or key is absent — preserves current behaviour
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
