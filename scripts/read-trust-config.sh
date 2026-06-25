#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
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

# Parse first so presence can also be derived from parsed rows.
if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-trust-config.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

AUTHORS=$(printf '%s\n' "$PARSED" \
  | awk -F= '$1 == "trust.journey_log_authors[]" { print "author=" substr($0, index($0, "=") + 1) }')

# Presence: the key is "present" if it appears as a `journey_log_authors:` key
# on any non-comment line (block form `  journey_log_authors:` OR flow form
# `trust: {journey_log_authors: ...}`) OR if yaml-lite parsed any entries. The
# key-line check (skipping whole-line comments) catches the empty-list cases in
# both forms (`[]` parses to zero rows but is an explicit "trust nobody"); the
# parsed-rows check catches populated configs. Without recognizing the flow form
# a configured allowlist would read as present=no and silently disable strict
# mode (#249 / #598 review, Copilot+Codex).
present_key=$(awk '
  { t=$0; sub(/^[[:space:]]+/,"",t) }
  t ~ /^#/ { next }
  /journey_log_authors[[:space:]]*:/ { found=1 }
  END { print (found ? "yes" : "no") }
' "$CONFIG")
if [ "$present_key" = "yes" ] || [ -n "$AUTHORS" ]; then
  echo "present=yes"
else
  echo "present=no"
fi

printf '%s\n' "$AUTHORS" | sed '/^$/d'
