#!/usr/bin/env bash
# owner: project-upgrade
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SYNC="$HERE/upgrade-sync.sh"; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PLG="$TMP/p"; PRJ="$TMP/j"; mkdir -p "$PLG/scripts" "$PRJ/scripts" "$PRJ/.arboretum"
echo a > "$PLG/scripts/x.sh"
echo contract > "$PLG/ARBORETUM.md"
plan="$(PROJECT_DIR="$PRJ" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' bash "$SYNC" --plan)"
# plan JSON must carry the four contracted top-level keys
for k in plugin_root actions policy removal_detection; do
  echo "$plan" | jq -e "has(\"$k\")" >/dev/null || { echo "FAIL: plan missing $k"; fail=1; }
done
# removal_detection is a closed enum
rd="$(echo "$plan" | jq -r '.removal_detection')"
case "$rd" in active|inconclusive) ;; *) echo "FAIL: removal_detection outside enum: $rd"; fail=1 ;; esac
# every action value is in the closed enum
bad="$(echo "$plan" | jq -r '.actions[]' | grep -Evx 'add|overwrite-safe|overwrite-local|keep-local|conflict|converged|remove-obsolete|unchanged|report-removed|report-only' || true)"
[ -z "$bad" ] || { echo "FAIL: action outside enum: $bad"; fail=1; }

# The default managed set includes the root agent contract, not just nested
# framework directories.
plan_default="$(PROJECT_DIR="$PRJ" UPGRADE_PLUGIN_ROOT="$PLG" bash "$SYNC" --plan)"
[ "$(echo "$plan_default" | jq -r '.actions["ARBORETUM.md"] // "null"')" = "add" ] \
  || { echo "FAIL: default plan does not add ARBORETUM.md"; fail=1; }
[ "$(echo "$plan_default" | jq -r '.policy["ARBORETUM.md"] // "null"')" = "3way" ] \
  || { echo "FAIL: default plan policy for ARBORETUM.md is not 3way"; fail=1; }

grep -q 'obsolete release helper' "$HERE/../docs/contracts/upgrade-sync.cli-contract.md" \
  || { echo "FAIL: upgrade contract does not document obsolete release helper cleanup"; fail=1; }

[ "$fail" = 0 ] && echo "ok: contract upgrade-sync"
exit "$fail"
