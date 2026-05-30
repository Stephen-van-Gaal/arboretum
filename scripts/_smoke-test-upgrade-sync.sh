#!/usr/bin/env bash
# owner: project-upgrade
# Unit smoke tests for upgrade-sync classification + helpers.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/upgrade-classify.sh
source "$HERE/lib/upgrade-classify.sh"

fail=0
check() { # desc expected actual
  if [ "$2" != "$3" ]; then echo "FAIL: $1 — expected '$2' got '$3'"; fail=1
  else echo "ok: $1"; fi
}

B=baaa; O=oooo; T=tttt   # distinct shas

check "framework update, untouched local" overwrite-safe "$(classify_file "$B" "$B" "$T" yes yes)"
check "nothing changed"                    unchanged      "$(classify_file "$B" "$B" "$B" yes yes)"
check "local edit, no framework change"    keep-local     "$(classify_file "$B" "$O" "$B" yes yes)"
check "both changed, diverged"             conflict       "$(classify_file "$B" "$O" "$T" yes yes)"
check "both changed, converged"            converged      "$(classify_file "$B" "$O" "$O" yes yes)"

# Fix 2: base-aware presence-mismatch cases
# "new in plugin" — empty base means genuinely new (never tracked)
check "new in plugin (empty base)"         add            "$(classify_file ''  ''  "$T" yes no)"
# "removed from framework" — base non-empty means we shipped it and plugin dropped it
check "removed from framework (base set)"  report-removed "$(classify_file "$B" "$O" '' no  yes)"
# user-owned file absent from plugin, no base — must NOT flag report-removed
check "user-owned absent-from-plugin"      unchanged      "$(classify_file ''  "$O" '' no  yes)"
# tracked file, locally deleted, plugin unchanged → keep-local (respect deletion)
check "tracked deleted, plugin unchanged"  keep-local     "$(classify_file "$B" ''  "$B" yes no)"
# tracked file, locally deleted, plugin changed → conflict (needs manual resolution)
check "tracked deleted, plugin changed"    conflict       "$(classify_file "$B" ''  "$T" yes no)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# manifest write/read round-trip
( cd "$TMP" && mkdir -p .arboretum scripts && echo 'x' > scripts/a.sh )
SYNC="$HERE/upgrade-sync.sh"
PROJECT_DIR="$TMP" bash "$SYNC" --write-manifest-entry scripts/a.sh 0.1.0 "deadbeef"
got="$(PROJECT_DIR="$TMP" bash "$SYNC" --read-manifest-sha scripts/a.sh)"
check "manifest round-trip sha" deadbeef "$got"
# write_manifest_entry records the per-file entry only; framework_version is set
# exclusively by bump_manifest_version (via --apply). Verify the file entry was
# written correctly without asserting the global version field here.
got_file_v="$(PROJECT_DIR="$TMP" bash "$SYNC" --read-manifest-sha scripts/a.sh)"
check "manifest round-trip: sha still readable after write" deadbeef "$got_file_v"

# fixture: a plugin root + a project tree, exercise --plan
PLG="$TMP/plugin"; PRJ="$TMP/proj"
mkdir -p "$PLG/scripts" "$PRJ/scripts" "$PRJ/.arboretum"
echo 'v2' > "$PLG/scripts/foo.sh"       # theirs
echo 'v1' > "$PRJ/scripts/foo.sh"       # ours == base (set below)
echo 'new' > "$PLG/scripts/new.sh"      # add
PROJECT_DIR="$PRJ" bash "$SYNC" --write-manifest-entry scripts/foo.sh 0.1.0 "$(shasum -a 256 "$PRJ/scripts/foo.sh"|awk '{print $1}')"
plan="$(PROJECT_DIR="$PRJ" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' bash "$SYNC" --plan)"
check "plan: foo overwrite-safe" overwrite-safe "$(echo "$plan" | jq -r '.actions["scripts/foo.sh"]')"
check "plan: new add"            add            "$(echo "$plan" | jq -r '.actions["scripts/new.sh"]')"

# bootstrap-project.sh must be excluded from the managed set (mirrors /init)
echo 'boot' > "$PLG/scripts/bootstrap-project.sh"
plan_x="$(PROJECT_DIR="$PRJ" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' bash "$SYNC" --plan)"
check "plan: bootstrap-project.sh excluded" null "$(echo "$plan_x" | jq -r '.actions["scripts/bootstrap-project.sh"] // "null"')"

# Fix 1: --plan must be read-only — no manifest created when none exists
PRJ_NOMNF="$TMP/proj-nomanifest"
mkdir -p "$PRJ_NOMNF/scripts"
echo 'v1' > "$PRJ_NOMNF/scripts/foo.sh"
PROJECT_DIR="$PRJ_NOMNF" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' bash "$SYNC" --plan >/dev/null
if [ -f "$PRJ_NOMNF/.arboretum/install-manifest.json" ]; then
  echo "FAIL: --plan created install-manifest.json (must be read-only)"; fail=1
else
  echo "ok: --plan did not create install-manifest.json"
fi

# Fix 3: scripts/lib/upgrade-classify.sh must be classified as 'add' when
# present in the plugin but absent in the project (default managed_globs includes scripts/lib/*).
PLG_LIB="$TMP/plugin-lib"; PRJ_LIB="$TMP/proj-lib"
mkdir -p "$PLG_LIB/scripts/lib" "$PRJ_LIB/scripts" "$PRJ_LIB/.arboretum"
echo '# classifier' > "$PLG_LIB/scripts/lib/upgrade-classify.sh"
# Write a manifest so the project is "known" but lib file has no base
jq -n '{schema_version:1, framework_version:"0.1.0", updated_at:null, files:{}}' \
  > "$PRJ_LIB/.arboretum/install-manifest.json"
plan_lib="$(PROJECT_DIR="$PRJ_LIB" UPGRADE_PLUGIN_ROOT="$PLG_LIB" bash "$SYNC" --plan)"
check "plan: scripts/lib/upgrade-classify.sh classified as add" \
  add "$(echo "$plan_lib" | jq -r '.actions["scripts/lib/upgrade-classify.sh"] // "null"')"

# Task 5: --apply and --bootstrap-manifest
# apply: overwrite-safe copies theirs, add creates, manifest bumps
PROJECT_DIR="$PRJ" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' \
  UPGRADE_PLUGIN_VERSION=0.2.0 bash "$SYNC" --apply >/dev/null
check "apply: foo took theirs"  v2 "$(cat "$PRJ/scripts/foo.sh")"
check "apply: new added"        new "$(cat "$PRJ/scripts/new.sh")"
check "apply: manifest bumped"  0.2.0 "$(PROJECT_DIR="$PRJ" bash "$SYNC" --read-manifest-version)"

# bootstrap on a pre-manifest project marks divergent files as conflict
PRJ2="$TMP/proj2"; mkdir -p "$PRJ2/scripts"
echo 'local-edit' > "$PRJ2/scripts/foo.sh"   # differs from plugin v2
PROJECT_DIR="$PRJ2" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' \
  UPGRADE_PLUGIN_VERSION=0.2.0 bash "$SYNC" --bootstrap-manifest >/dev/null
nextplan="$(PROJECT_DIR="$PRJ2" UPGRADE_PLUGIN_ROOT="$PLG" UPGRADE_MANAGED_GLOBS='scripts/*.sh' bash "$SYNC" --plan)"
check "bootstrap: divergent => conflict" conflict "$(echo "$nextplan" | jq -r '.actions["scripts/foo.sh"]')"

# Fix 6: arity check — --read-manifest-sha with no path arg must exit 2
ARITY_PRJ="$TMP/arity-proj"
mkdir -p "$ARITY_PRJ/.arboretum"
arity_exit=0
( PROJECT_DIR="$ARITY_PRJ" bash "$SYNC" --read-manifest-sha ) 2>/dev/null || arity_exit=$?
check "arity: --read-manifest-sha missing arg exits 2" 2 "$arity_exit"

# Fix 9: version must NOT be bumped when plan contains conflict entries
PRJ9="$TMP/proj9"
mkdir -p "$PRJ9/scripts" "$PRJ9/.arboretum"
PLG9="$TMP/plugin9"
mkdir -p "$PLG9/scripts"
# foo.sh: base tracks old content; plugin changed it; local is different too → conflict
echo 'base'     > "$PRJ9/scripts/foo.sh"
echo 'plugin'   > "$PLG9/scripts/foo.sh"
# safe.sh: base matches current; plugin changed → overwrite-safe
echo 'safe_old' > "$PRJ9/scripts/safe.sh"
echo 'safe_new' > "$PLG9/scripts/safe.sh"
# Seed manifest: foo.sh base = "base" content hash, safe.sh base = "safe_old" hash
PROJECT_DIR="$PRJ9" bash "$SYNC" --write-manifest-entry \
  scripts/foo.sh 0.1.0 "$(shasum -a 256 "$PRJ9/scripts/foo.sh" | awk '{print $1}')"
# Now diverge foo.sh locally (conflict: local differs, plugin also differs from base)
echo 'local-edit' > "$PRJ9/scripts/foo.sh"
PROJECT_DIR="$PRJ9" bash "$SYNC" --write-manifest-entry \
  scripts/safe.sh 0.1.0 "$(shasum -a 256 "$PRJ9/scripts/safe.sh" | awk '{print $1}')"
old_v="$(PROJECT_DIR="$PRJ9" bash "$SYNC" --read-manifest-version)"
PROJECT_DIR="$PRJ9" UPGRADE_PLUGIN_ROOT="$PLG9" UPGRADE_MANAGED_GLOBS='scripts/*.sh' \
  UPGRADE_PLUGIN_VERSION=0.2.0 bash "$SYNC" --apply >/dev/null
new_v="$(PROJECT_DIR="$PRJ9" bash "$SYNC" --read-manifest-version)"
check "version not bumped when conflicts remain" "$old_v" "$new_v"

exit "$fail"
