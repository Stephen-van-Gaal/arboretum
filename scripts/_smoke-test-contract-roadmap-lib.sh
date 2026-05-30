#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-lib.sh — Contract test for
# docs/contracts/roadmap-lib.contract.md. Asserts RL-1..RL-7 against
# scripts/roadmap/lib.sh.
#
# The library resolves the project root via `git rev-parse --show-toplevel`,
# so each case runs inside a throwaway git repo (mktemp + git init) that
# carries a fixture roadmap.config.yaml. Functions are exercised in a
# subshell that cd's into the fixture root and sources the lib, so the
# real lib.sh is the unit under test. Covers the load-bearing helpers
# (root/config resolution, the scalar/list getters, pulse round-trip);
# trivial wrappers (require_gh, label_exists) are not network-tested here.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# Build a git-repo fixture with a block-style config.
git -C "$FIX" init -q
cat > "$FIX/roadmap.config.yaml" <<'YAML'
wip_limit: "3"   # inline comment must be stripped
profile: lean
component_values:
  - skills
  - workflows
  - hooks
YAML

# Helper: run a function inside the fixture root with the lib sourced.
# shellcheck source=scripts/roadmap/lib.sh
inlib() { ( cd "$FIX" && source "$LIB" && "$@" ); }

# RL-1 — project root resolves to the fixture repo toplevel
root=$(inlib roadmap_project_root)
# macOS /tmp symlinks to /private/tmp; compare basenames-resolved paths.
if [ -n "$root" ] && [ "$(cd "$root" && pwd -P)" = "$(cd "$FIX" && pwd -P)" ]; then pass RL-1
else fail_case RL-1 "root=$root fix=$FIX"; fi

# RL-2 — config path present, then absent
cpath=$(inlib roadmap_config_path)
[ -n "$cpath" ] && pass "RL-2 (present)" || fail_case "RL-2 (present)" "cpath empty"
mv "$FIX/roadmap.config.yaml" "$FIX/roadmap.config.yaml.bak"
cpath_absent=$(inlib roadmap_config_path)
[ -z "$cpath_absent" ] && pass "RL-2 (absent)" || fail_case "RL-2 (absent)" "got=$cpath_absent"
mv "$FIX/roadmap.config.yaml.bak" "$FIX/roadmap.config.yaml"

# RL-3 — scalar getter: quotes + inline comment stripped
wip=$(inlib roadmap_config_get wip_limit)
[ "$wip" = "3" ] && pass RL-3 || fail_case RL-3 "wip=[$wip]"

# RL-4 — malformed key name → nonzero, no value
badout=$(inlib roadmap_config_get 'bad key' 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$badout" ] && pass RL-4 || fail_case RL-4 "rc=$rc out=[$badout]"

# RL-5 — list getter: block style, then flow style.
# Forced onto the python3 fallback: the list getter's yq path uses jq-syntax
# (`.key[]? // empty`) that mikefarah yq rejects ("lexer: invalid input text
# 'empty'"), a pre-existing lib.sh bug tracked as #412. Hide yq (mirror every
# OTHER PATH executable into a shadow bin) so `command -v yq` fails and the
# portable python3 path runs on every platform. See roadmap-lib.contract.md
# § Invariants "list-getter yq-path gap".
NOYQ_BIN="$FIX/.noyq-bin"; mkdir -p "$NOYQ_BIN"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = yq ] && continue
    [ -e "$NOYQ_BIN/$_b" ] || ln -s "$_f" "$NOYQ_BIN/$_b" 2>/dev/null || true
  done
done
# shellcheck source=scripts/roadmap/lib.sh
inlib_noyq() { ( cd "$FIX" && PATH="$NOYQ_BIN" && source "$LIB" && "$@" ); }

list_block=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',' )
[ "$list_block" = "skills,workflows,hooks," ] && pass "RL-5 (block)" || fail_case "RL-5 (block)" "got=[$list_block]"
# flow style
cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values: [skills, workflows, hooks]
YAML
list_flow=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',')
[ "$list_flow" = "skills,workflows,hooks," ] && pass "RL-5 (flow)" || fail_case "RL-5 (flow)" "got=[$list_flow]"

# RL-6 — pulse readers fail-silent when pulse file is missing
[ ! -f "$FIX/.arboretum/roadmap-pulse.json" ] || rm -f "$FIX/.arboretum/roadmap-pulse.json"
pf=$(inlib roadmap_pulse_get_field last_maintain_run); rc=$?
pn=$(inlib roadmap_pulse_get_nag maintain-overdue); rc2=$?
[ "$rc" = 0 ] && [ -z "$pf" ] && [ "$rc2" = 0 ] && [ -z "$pn" ] && pass RL-6 || fail_case RL-6 "rc=$rc pf=[$pf] rc2=$rc2 pn=[$pn]"

# RL-7 — pulse round-trip: bootstrap, update a field, read it back
inlib roadmap_pulse_bootstrap
inlib roadmap_pulse_update_field last_maintain_run "2026-05-30T12:00:00Z"
got=$(inlib roadmap_pulse_get_field last_maintain_run)
[ "$got" = "2026-05-30T12:00:00Z" ] && pass RL-7 || fail_case RL-7 "got=[$got] pulse=$(cat "$FIX/.arboretum/roadmap-pulse.json" 2>/dev/null)"

[ "$fail" = 0 ] && echo "roadmap-lib contract: ALL PASS" || exit 1
