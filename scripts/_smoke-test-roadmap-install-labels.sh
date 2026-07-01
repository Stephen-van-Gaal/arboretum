#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# ci-parallel: serial
# Smoke test for scripts/roadmap/install-labels.sh
#
# Uses --dry-run mode to avoid touching any GitHub state. Asserts:
# - All framework-fixed labels are present
# - Component labels appear when config is supplied
# - Audience labels appear when config has audience_values
# - --no-components excludes component:* and audience:* labels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/roadmap/install-labels.sh"
CONFIG="$SCRIPT_DIR/_fixtures/roadmap/sample-config.yaml"

[ -f "$INSTALLER" ] || { echo "FAIL: $INSTALLER not found" >&2; exit 1; }
[ -f "$CONFIG" ]    || { echo "FAIL: $CONFIG not found" >&2; exit 1; }

fail=0

# Test 1: framework-fixed labels always appear
output="$(bash "$INSTALLER" --dry-run --no-components)"
for label in \
  type:epic type:feature type:bug type:spike type:refactor type:docs type:chore \
  horizon:now horizon:next horizon:later \
  blocked agent-ready agent-prep:in-progress provisionally-resolved provisionally-stale \
  autonomy:pause-at-land autonomy:pause-at-merge autonomy:auto-merge
do
  if printf '%s\n' "$output" | cut -f1 | grep -Fxq "$label"; then
    echo "PASS  framework-fixed: $label"
  else
    echo "FAIL  framework-fixed: $label missing"
    fail=1
  fi
done

# Test 1b: the autonomy:* vocabulary is a CLOSED set of exactly three labels
# (#915 slice 1). design-only is the absence of a label, never an emitted one.
autonomy_count="$(printf '%s\n' "$output" | cut -f1 | grep -c '^autonomy:' || true)"
if [ "$autonomy_count" -eq 3 ]; then
  echo "PASS  autonomy vocabulary is closed (exactly 3 labels)"
else
  echo "FAIL  autonomy vocabulary: expected exactly 3 autonomy:* labels, got $autonomy_count"
  fail=1
fi
if printf '%s\n' "$output" | cut -f1 | grep -Fxq "autonomy:design-only"; then
  echo "FAIL  autonomy:design-only must NOT be a label (it is the absence of a grant)"
  fail=1
else
  echo "PASS  autonomy:design-only is correctly not a label"
fi

# Test 2: --no-components excludes component:* and audience:*
component_count="$(printf '%s\n' "$output" | cut -f1 | grep -c '^component:' || true)"
audience_count="$(printf '%s\n' "$output" | cut -f1 | grep -c '^audience:' || true)"
[ "$component_count" -eq 0 ] && [ "$audience_count" -eq 0 ] || {
  echo "FAIL  --no-components: expected 0 components, 0 audiences; got $component_count, $audience_count"
  fail=1
}
[ "$component_count" -eq 0 ] && echo "PASS  --no-components: no component:* labels"
[ "$audience_count" -eq 0 ] && echo "PASS  --no-components: no audience:* labels"

# Test 3: with --config, component_values become component:* labels
output="$(bash "$INSTALLER" --dry-run --config "$CONFIG")"
for c in pipeline editorial infra; do
  if printf '%s\n' "$output" | cut -f1 | grep -Fxq "component:$c"; then
    echo "PASS  config component: component:$c"
  else
    echo "FAIL  config component: component:$c missing"
    fail=1
  fi
done

# Test 4: with --config, audience_values become audience:* labels
for a in csc-pilot post-pilot; do
  if printf '%s\n' "$output" | cut -f1 | grep -Fxq "audience:$a"; then
    echo "PASS  config audience: audience:$a"
  else
    echo "FAIL  config audience: audience:$a missing"
    fail=1
  fi
done

# Test 5: idempotency dry-run is stable (re-running produces same output)
output2="$(bash "$INSTALLER" --dry-run --config "$CONFIG")"
if [ "$output" = "$output2" ]; then
  echo "PASS  idempotency: two dry-run invocations produce identical output"
else
  echo "FAIL  idempotency: two dry-run invocations differ"
  fail=1
fi

exit $fail
