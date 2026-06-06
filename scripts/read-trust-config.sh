#!/usr/bin/env bash
# owner: pipeline-state-tracking
# read-trust-config.sh — Read the journey-log author allowlist from
# .arboretum.yml (trust.journey_log_authors). Emits:
#   present=yes|no          (textual presence of the key — distinguishes
#                            an explicit empty list from an absent key,
#                            which yaml-lite cannot)
#   author=<login>          (zero or more lines, one per allowlisted login)
#
# Usage: read-trust-config.sh [<config-file>]   (default: .arboretum.yml)
# Exit: 0 success; 1 config file not found / invalid YAML.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "read-trust-config.sh requires bash" >&2; exit 1; }

CONFIG="${1:-.arboretum.yml}"
[ -f "$CONFIG" ] || { echo "read-trust-config.sh: config not found: $CONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-trust-config.sh: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

# Presence: textual check (yaml-lite drops empty lists, so it cannot tell
# present-but-empty from absent). The key name is unique in the constrained
# YAML subset, so a line-anchored grep is sufficient.
if grep -Eq '^[[:space:]]*journey_log_authors[[:space:]]*:' "$CONFIG"; then
  echo "present=yes"
else
  echo "present=no"
fi

if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-trust-config.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

printf '%s\n' "$PARSED" \
  | awk -F= '$1 == "trust.journey_log_authors[]" { print "author=" substr($0, index($0, "=") + 1) }'
