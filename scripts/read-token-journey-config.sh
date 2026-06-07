#!/usr/bin/env bash
# owner: token-accounting
# read-token-journey-config.sh — Read token_journey config from .arboretum.yml.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "read-token-journey-config.sh requires bash" >&2; exit 1; }
CONFIG="${1:-.arboretum.yml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-token-journey-config.sh: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

enabled=false; output_dir=".arboretum/token-journey"; format=md
if [ -f "$CONFIG" ]; then
  if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
    echo "read-token-journey-config.sh: invalid YAML-lite in $CONFIG" >&2
    printf '%s\n' "$PARSED" >&2; exit 1
  fi
  v=$(printf '%s\n' "$PARSED" | awk -F= '$1=="token_journey.enabled"{print substr($0,index($0,"=")+1);exit}')
  [ -n "$v" ] && enabled="$v"
  v=$(printf '%s\n' "$PARSED" | awk -F= '$1=="token_journey.output_dir"{print substr($0,index($0,"=")+1);exit}')
  [ -n "$v" ] && output_dir="$v"
  v=$(printf '%s\n' "$PARSED" | awk -F= '$1=="token_journey.format"{print substr($0,index($0,"=")+1);exit}')
  [ -n "$v" ] && format="$v"
fi
case "$enabled" in true|false) :;; *) echo "read-token-journey-config.sh: enabled must be true|false, got: $enabled" >&2; exit 1;; esac
case "$format" in md|json) :;; *) echo "read-token-journey-config.sh: format must be md|json, got: $format" >&2; exit 1;; esac
printf 'enabled=%s\noutput_dir=%s\nformat=%s\n' "$enabled" "$output_dir" "$format"
