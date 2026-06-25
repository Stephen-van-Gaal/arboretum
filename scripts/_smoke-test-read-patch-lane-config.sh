#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-read-patch-lane-config.sh — Contract checks for
# scripts/read-patch-lane-config.sh.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/read-patch-lane-config.sh"
TMP="${TMPDIR:-/tmp}/patch-lane-config-smoke.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

run_helper() {
  local config="$1"
  local out="$TMP/out"
  local err="$TMP/err"
  set +e
  bash "$HELPER" "$config" >"$out" 2>"$err"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$TMP/rc"
}

run_helper_default_from() {
  local dir="$1"
  local out="$TMP/out"
  local err="$TMP/err"
  set +e
  (cd "$dir" && bash "$HELPER" >"$out" 2>"$err")
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$TMP/rc"
}

mkdir -p "$TMP/default-root"
cat >"$TMP/default-root/.arboretum.yml" <<'YAML'
layer: 2
patch_lane:
  investigation_budget_minutes: 9
YAML
run_helper_default_from "$TMP/default-root"
[ "$(cat "$TMP/rc")" = "0" ] || fail "default .arboretum.yml path should pass" "$(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "investigation_budget_minutes=9" ] \
  || fail "default .arboretum.yml budget should be 9" "$(cat "$TMP/out")"
ok "default path reads .arboretum.yml"

cat >"$TMP/default.yaml" <<'YAML'
layer: 2
YAML
run_helper "$TMP/default.yaml"
[ "$(cat "$TMP/rc")" = "0" ] || fail "default config should pass" "$(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "investigation_budget_minutes=15" ] \
  || fail "default budget should be 15" "$(cat "$TMP/out")"
ok "default budget is 15"

cat >"$TMP/explicit.yaml" <<'YAML'
patch_lane:
  investigation_budget_minutes: 7
YAML
run_helper "$TMP/explicit.yaml"
[ "$(cat "$TMP/rc")" = "0" ] || fail "explicit config should pass" "$(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "investigation_budget_minutes=7" ] \
  || fail "explicit budget should be 7" "$(cat "$TMP/out")"
ok "explicit budget is read"

cat >"$TMP/zero.yaml" <<'YAML'
patch_lane:
  investigation_budget_minutes: 0
YAML
run_helper "$TMP/zero.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "zero budget should fail"
grep -q "positive integer" "$TMP/err" || fail "zero diagnostic should name positive integer" "$(cat "$TMP/err")"
ok "zero budget is rejected"

cat >"$TMP/non-integer.yaml" <<'YAML'
patch_lane:
  investigation_budget_minutes: fifteen
YAML
run_helper "$TMP/non-integer.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "non-integer budget should fail"
grep -q "positive integer" "$TMP/err" || fail "non-integer diagnostic should name positive integer" "$(cat "$TMP/err")"
ok "non-integer budget is rejected"

cat >"$TMP/invalid.yaml" <<'YAML'
patch_lane:
  investigation_budget_minutes
YAML
run_helper "$TMP/invalid.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "invalid YAML-lite should fail"
grep -q "invalid YAML-lite" "$TMP/err" || fail "invalid YAML diagnostic missing" "$(cat "$TMP/err")"
ok "invalid YAML-lite is rejected"

run_helper "$TMP/missing.yaml"
[ "$(cat "$TMP/rc")" != "0" ] || fail "missing config should fail"
grep -q "config not found" "$TMP/err" || fail "missing config diagnostic missing" "$(cat "$TMP/err")"
ok "missing config is rejected"

echo "read-patch-lane-config smoke: ALL PASS"
