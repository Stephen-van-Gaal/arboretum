#!/usr/bin/env bash
# owner: autonomy-grants
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-read-autonomy-config.sh — Contract checks for
# scripts/read-autonomy-config.sh (the .arboretum.yml autonomy: block reader).
#
# Covers: documented defaults when block/keys absent; valid block parse;
# the D7 floor guarantee (a zero/negative/non-numeric trigger is rejected —
# the floor is tunable, not removable); default_grant closed-vocabulary
# rejection; auto_merge_enabled / cost_ceiling_overridable boolean validation;
# fail-closed on malformed YAML; missing config rejection.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/read-autonomy-config.sh"
TMP="${TMPDIR:-/tmp}/autonomy-config-smoke.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

run_helper() {
  local config="$1"
  set +e
  bash "$HELPER" "$config" >"$TMP/out" 2>"$TMP/err"
  printf '%s\n' "$?" >"$TMP/rc"
  set -e
}

emits() { grep -qxF "$1" "$TMP/out"; }

# ── Defaults when the block is entirely absent ──────────────────────
cat >"$TMP/no-block.yaml" <<'YAML'
layer: 2
backend: github
YAML
run_helper "$TMP/no-block.yaml"
[ "$(cat "$TMP/rc")" = "0" ] || fail "absent block should pass with defaults" "$(cat "$TMP/err")"
emits "default_grant=pause-at-merge"        || fail "default default_grant" "$(cat "$TMP/out")"
emits "ci_hard_fail_attempts=2"             || fail "default ci_hard_fail_attempts" "$(cat "$TMP/out")"
emits "thrash_window_rounds=3"              || fail "default thrash_window_rounds" "$(cat "$TMP/out")"
emits "cost_ceiling_tokens=500000"          || fail "default cost_ceiling_tokens" "$(cat "$TMP/out")"
emits "cost_ceiling_overridable=true"       || fail "default cost_ceiling_overridable" "$(cat "$TMP/out")"
emits "auto_merge_enabled=false"            || fail "default auto_merge_enabled (must default false)" "$(cat "$TMP/out")"
ok "absent block yields conservative defaults"

# ── A fully-specified valid block ───────────────────────────────────
cat >"$TMP/valid.yaml" <<'YAML'
autonomy:
  default_grant: auto-merge
  triggers:
    ci_hard_fail_attempts: 5
    thrash_window_rounds: 4
    cost_ceiling_tokens: 1000000
  cost_ceiling_overridable: false
  auto_merge_enabled: true
YAML
run_helper "$TMP/valid.yaml"
[ "$(cat "$TMP/rc")" = "0" ] || fail "valid block should pass" "$(cat "$TMP/err")"
emits "default_grant=auto-merge"     || fail "valid default_grant" "$(cat "$TMP/out")"
emits "ci_hard_fail_attempts=5"      || fail "valid ci_hard_fail_attempts" "$(cat "$TMP/out")"
emits "thrash_window_rounds=4"       || fail "valid thrash_window_rounds" "$(cat "$TMP/out")"
emits "cost_ceiling_tokens=1000000"  || fail "valid cost_ceiling_tokens" "$(cat "$TMP/out")"
emits "cost_ceiling_overridable=false" || fail "valid cost_ceiling_overridable" "$(cat "$TMP/out")"
emits "auto_merge_enabled=true"      || fail "valid auto_merge_enabled" "$(cat "$TMP/out")"
ok "valid block parses"

# ── Partial block: present keys win, absent keys default ────────────
cat >"$TMP/partial.yaml" <<'YAML'
autonomy:
  triggers:
    cost_ceiling_tokens: 250000
YAML
run_helper "$TMP/partial.yaml"
[ "$(cat "$TMP/rc")" = "0" ] || fail "partial block should pass" "$(cat "$TMP/err")"
emits "cost_ceiling_tokens=250000" || fail "partial overrides one key" "$(cat "$TMP/out")"
emits "default_grant=pause-at-merge" || fail "partial defaults the rest" "$(cat "$TMP/out")"
emits "auto_merge_enabled=false"    || fail "partial keeps conservative auto_merge default" "$(cat "$TMP/out")"
ok "partial block defaults the unspecified keys"

# ── D7 floor: a zero trigger is rejected (tunable, not removable) ────
for badval in 0 -1 nope; do
  cat >"$TMP/floor.yaml" <<YAML
autonomy:
  triggers:
    ci_hard_fail_attempts: $badval
YAML
  run_helper "$TMP/floor.yaml"
  [ "$(cat "$TMP/rc")" != "0" ] || fail "trigger value '$badval' must be rejected (floor not removable)"
  grep -qi "positive integer" "$TMP/err" || fail "diagnostic for '$badval' should name positive integer" "$(cat "$TMP/err")"
done
ok "zero/negative/non-numeric trigger thresholds are rejected (floor guarantee)"

# Each trigger key is guarded, not just the first.
cat >"$TMP/floor2.yaml" <<'YAML'
autonomy:
  triggers:
    cost_ceiling_tokens: 0
YAML
run_helper "$TMP/floor2.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "cost_ceiling_tokens=0 must be rejected"
ok "every trigger threshold is floor-guarded"

# ── default_grant outside the closed vocabulary is rejected ─────────
cat >"$TMP/badgrant.yaml" <<'YAML'
autonomy:
  default_grant: yolo
YAML
run_helper "$TMP/badgrant.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "out-of-vocabulary default_grant must be rejected"
grep -qi "default_grant" "$TMP/err" || fail "diagnostic should name default_grant" "$(cat "$TMP/err")"
ok "default_grant closed-vocabulary is enforced"

# default_grant may not be design-only — that is the *absence* of a grant,
# not a settable default tier.
cat >"$TMP/designonly.yaml" <<'YAML'
autonomy:
  default_grant: design-only
YAML
run_helper "$TMP/designonly.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "default_grant=design-only must be rejected"
ok "default_grant cannot be design-only"

# ── boolean fields validated ────────────────────────────────────────
cat >"$TMP/badbool.yaml" <<'YAML'
autonomy:
  auto_merge_enabled: maybe
YAML
run_helper "$TMP/badbool.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "non-boolean auto_merge_enabled must be rejected"
grep -qi "auto_merge_enabled" "$TMP/err" || fail "diagnostic should name auto_merge_enabled" "$(cat "$TMP/err")"
ok "auto_merge_enabled boolean is enforced"

# ── fail closed on malformed YAML ───────────────────────────────────
cat >"$TMP/malformed.yaml" <<'YAML'
autonomy:
  default_grant
YAML
run_helper "$TMP/malformed.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "malformed YAML must fail closed"
grep -qi "invalid YAML-lite" "$TMP/err" || fail "malformed diagnostic should name invalid YAML-lite" "$(cat "$TMP/err")"
ok "malformed config fails closed"

# ── missing config file ─────────────────────────────────────────────
run_helper "$TMP/does-not-exist.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "missing config must fail"
grep -qi "config not found" "$TMP/err" || fail "missing diagnostic should say config not found" "$(cat "$TMP/err")"
ok "missing config is rejected"

# ── default-path resolution (reads ./.arboretum.yml) ────────────────
mkdir -p "$TMP/proj"
cat >"$TMP/proj/.arboretum.yml" <<'YAML'
autonomy:
  default_grant: pause-at-land
YAML
set +e
( cd "$TMP/proj" && bash "$HELPER" >"$TMP/out" 2>"$TMP/err" )
printf '%s\n' "$?" >"$TMP/rc"
set -e
[ "$(cat "$TMP/rc")" = "0" ] || fail "default path should read ./.arboretum.yml" "$(cat "$TMP/err")"
emits "default_grant=pause-at-land" || fail "default-path value" "$(cat "$TMP/out")"
ok "default path reads ./.arboretum.yml"

echo "read-autonomy-config smoke: ALL PASS"
