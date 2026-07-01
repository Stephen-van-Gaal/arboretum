#!/usr/bin/env bash
# owner: autonomy-grants
# scope: plugin-only
# read-autonomy-config.sh — Read the autonomy-grant gate configuration from
# .arboretum.yml (the `autonomy:` block). The single authoritative source for
# every gate parameter (#915 D7); slices 2–5 read their thresholds here rather
# than embedding defaults in skill prose.
#
# Emits one `key=value` line per parameter (flattened — the consumer does not
# care about the YAML nesting):
#   default_grant=<pause-at-land|pause-at-merge|auto-merge>
#   ci_hard_fail_attempts=<positive int>
#   thrash_window_rounds=<positive int>
#   cost_ceiling_tokens=<positive int>
#   cost_ceiling_overridable=<true|false>
#   auto_merge_enabled=<true|false>
#
# Defaults (applied when the block or a key is absent) keep a project
# conservative by construction:
#   default_grant=pause-at-merge, ci_hard_fail_attempts=2,
#   thrash_window_rounds=3, cost_ceiling_tokens=500000,
#   cost_ceiling_overridable=true, auto_merge_enabled=false.
#
# The trigger floor is *tunable* but not *removable* (#915 D3/D7): a trigger
# threshold of 0 / negative / non-numeric is REJECTED so the floor survives
# misconfiguration. `default_grant` is validated against the closed `autonomy:*`
# vocabulary. Booleans are validated. A malformed .arboretum.yml fails closed
# (the reader never reads a bad config as "absent → permissive").
#
# Usage: read-autonomy-config.sh [<config-file>]   (default: .arboretum.yml)
# Exit: 0 success; 1 config not found / invalid YAML / validation failure.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "read-autonomy-config.sh requires bash" >&2; exit 1; }

CONFIG="${1:-.arboretum.yml}"
[ -f "$CONFIG" ] || { echo "read-autonomy-config.sh: config not found: $CONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-autonomy-config.sh: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

# Fail closed: a malformed .arboretum.yml is never read as "absent → defaults"
# (mirrors the trust-config discipline, #249).
if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-autonomy-config.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

# Pull a flattened key (e.g. autonomy.triggers.ci_hard_fail_attempts); empty if absent.
get() { printf '%s\n' "$PARSED" | awk -F= -v k="$1" '$1 == k { print substr($0, index($0, "=") + 1); exit }'; }

DEFAULT_GRANT=$(get "autonomy.default_grant")
CI_ATTEMPTS=$(get "autonomy.triggers.ci_hard_fail_attempts")
THRASH=$(get "autonomy.triggers.thrash_window_rounds")
COST=$(get "autonomy.triggers.cost_ceiling_tokens")
OVERRIDABLE=$(get "autonomy.cost_ceiling_overridable")
AUTO_MERGE=$(get "autonomy.auto_merge_enabled")

# Apply conservative defaults for any absent key.
[ -n "$DEFAULT_GRANT" ] || DEFAULT_GRANT="pause-at-merge"
[ -n "$CI_ATTEMPTS" ]   || CI_ATTEMPTS="2"
[ -n "$THRASH" ]        || THRASH="3"
[ -n "$COST" ]          || COST="500000"
[ -n "$OVERRIDABLE" ]   || OVERRIDABLE="true"
[ -n "$AUTO_MERGE" ]    || AUTO_MERGE="false"

# ── Validation ──────────────────────────────────────────────────────

# Trigger floor: positive integer only. A value of 0 / negative / non-numeric
# would remove the floor — rejected per D3/D7 (tunable, not removable).
validate_floor() {
  local key="$1" val="$2"
  case "$val" in
    ''|*[!0-9]*|0|0[0-9]*)
      echo "read-autonomy-config.sh: autonomy.triggers.$key must be a positive integer (the trigger floor is tunable, not removable), got: $val" >&2
      exit 1
      ;;
  esac
}
validate_floor "ci_hard_fail_attempts" "$CI_ATTEMPTS"
validate_floor "thrash_window_rounds"  "$THRASH"
validate_floor "cost_ceiling_tokens"   "$COST"

# default_grant: closed vocabulary. design-only is the ABSENCE of a grant, not a
# settable default tier, so it is excluded here.
case "$DEFAULT_GRANT" in
  pause-at-land|pause-at-merge|auto-merge) ;;
  *)
    echo "read-autonomy-config.sh: autonomy.default_grant must be one of pause-at-land|pause-at-merge|auto-merge, got: $DEFAULT_GRANT" >&2
    exit 1
    ;;
esac

validate_bool() {
  local key="$1" val="$2"
  case "$val" in
    true|false) ;;
    *) echo "read-autonomy-config.sh: autonomy.$key must be true or false, got: $val" >&2; exit 1 ;;
  esac
}
validate_bool "cost_ceiling_overridable" "$OVERRIDABLE"
validate_bool "auto_merge_enabled"       "$AUTO_MERGE"

# ── Emit ────────────────────────────────────────────────────────────
printf 'default_grant=%s\n' "$DEFAULT_GRANT"
printf 'ci_hard_fail_attempts=%s\n' "$CI_ATTEMPTS"
printf 'thrash_window_rounds=%s\n' "$THRASH"
printf 'cost_ceiling_tokens=%s\n' "$COST"
printf 'cost_ceiling_overridable=%s\n' "$OVERRIDABLE"
printf 'auto_merge_enabled=%s\n' "$AUTO_MERGE"
