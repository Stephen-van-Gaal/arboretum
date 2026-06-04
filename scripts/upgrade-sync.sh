#!/usr/bin/env bash
# owner: project-upgrade
# uses: definitions/install-manifest-schema.md @v1
# upgrade-sync.sh — sync vendored framework files from the installed plugin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/upgrade-classify.sh
source "$HERE/lib/upgrade-classify.sh"
# shellcheck source=scripts/lib/yaml-lite.sh
source "$HERE/lib/yaml-lite.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PROJECT_DIR:-$(pwd)}}"
MANIFEST="$PROJECT_DIR/.arboretum/install-manifest.json"

die() { echo "upgrade-sync: $*" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

# --- plugin discovery (mirrors refresh-update-cache.sh) -------------------
discover_plugin_root() {
  local cache="$HOME/.claude/plugins/cache" best="" bestver=""
  local manifest plugver dir
  while IFS= read -r manifest; do
    grep -Eq '"name"[[:space:]]*:[[:space:]]*"arboretum"' "$manifest" || continue
    plugver="$(grep -Eo '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" | head -1 | grep -Eo '[0-9][^"]*')"
    dir="$(cd "$(dirname "$manifest")/.." && pwd)"
    if [ -z "$bestver" ] || [ "$(printf '%s\n%s\n' "$bestver" "$plugver" | sort -V | tail -1)" = "$plugver" ]; then
      best="$dir"; bestver="$plugver"
    fi
  done < <(find "$cache" -type f -path '*/.claude-plugin/plugin.json' 2>/dev/null)
  [ -n "$best" ] || return 1
  echo "$best	$bestver"
}

# --- manifest I/O ---------------------------------------------------------
manifest_init_if_missing() {
  need_jq
  mkdir -p "$(dirname "$MANIFEST")"
  [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1 && return 0
  jq -n '{schema_version:1, framework_version:null, updated_at:null, files:{}}' > "$MANIFEST"
}
read_manifest_sha()     { need_jq; jq -r --arg p "$1" '.files[$p].sha256 // empty' "$MANIFEST" 2>/dev/null; }
read_manifest_version() { need_jq; jq -r '.framework_version // empty' "$MANIFEST" 2>/dev/null; }
write_manifest_entry() { # path version sha
  need_jq; manifest_init_if_missing
  local tmp; tmp="$(mktemp "$(dirname "$MANIFEST")/.manifest.XXXXXX")"
  # Only record the per-file entry. framework_version is set exclusively by
  # bump_manifest_version so that cmd_apply can conditionally skip the bump
  # when conflicts remain (Fix 9). Setting it here would bypass that gate.
  jq --arg p "$1" --arg v "$2" --arg s "$3" \
     '.files[$p] = {version:$v, sha256:$s}' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST" || rm -f "$tmp"
}
remove_manifest_entry() { # path
  need_jq
  [ -f "$MANIFEST" ] || return 0
  local tmp; tmp="$(mktemp "$(dirname "$MANIFEST")/.manifest.XXXXXX")"
  jq --arg p "$1" 'del(.files[$p])' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST" || rm -f "$tmp"
}

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

yaml_lite_value() {
  local yaml_file="$1" key="$2"
  [ -f "$yaml_file" ] || return 1
  yaml_lite_parse file "$yaml_file" | awk -v key="$key" '
    {
      sep = index($0, "=")
      if (sep == 0) { next }
      parsed_key = substr($0, 1, sep - 1)
      if (parsed_key == key) {
        print substr($0, sep + 1)
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

normalize_backend_value() {
  case "$1" in
    ""|null|Null|NULL|~) printf '%s\n' "" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

project_backend_for_config() {
  local config="$PROJECT_DIR/roadmap.config.yaml" backend=""
  if [ -f "$config" ]; then
    if backend="$(yaml_lite_value "$config" backend 2>/dev/null)"; then
      backend="$(normalize_backend_value "$backend")"
    else
      backend="$(yaml_lite_value "$config" roadmap.backend 2>/dev/null || true)"
      backend="$(normalize_backend_value "$backend")"
    fi
  fi
  case "$backend" in
    ""|github) printf '%s\n' "github" ;;
    azure|ado|azure-devops) printf '%s\n' "azure-devops" ;;
    *) printf '%s\n' "$backend" ;;
  esac
}

ensure_arboretum_config() {
  [ -f "$PROJECT_DIR/.arboretum.yml" ] && return 0
  [ -f "$PROJECT_DIR/roadmap.config.yaml" ] || return 0
  local backend
  backend="$(project_backend_for_config)"
  cat > "$PROJECT_DIR/.arboretum.yml" <<YAML
# Arboretum project configuration
# layer: 0 = foundation, 1 = structure, 2 = governance
layer: 0
# Tracker/repo backend. Preserved from legacy roadmap.config.yaml when present.
backend: $backend
YAML
}

# Files matched by a managed glob but explicitly NOT propagated by /upgrade
# (mirrors /init's exclusion). rel is repo-root-relative (e.g. scripts/bootstrap-project.sh).
is_excluded() {
  case "$1" in
    scripts/bootstrap-project.sh) return 0 ;;
    scripts/_smoke-test-*.sh) return 0 ;;
    *) return 1 ;;
  esac
}

obsolete_removal_safe() {
  local rel="$1" proot="$2"
  local ours base theirs=""
  [ -f "$PROJECT_DIR/$rel" ] || return 1
  ours="$(sha "$PROJECT_DIR/$rel")"
  base="$(read_manifest_sha "$rel")"
  [ -f "$proot/$rel" ] && theirs="$(sha "$proot/$rel")"
  [ -n "$base" ] && [ "$ours" = "$base" ] && return 0
  [ -n "$theirs" ] && [ "$ours" = "$theirs" ] && return 0
  return 1
}

# Managed categories: glob (relative to root) -> policy(3way|report-only)
# UPGRADE_MANAGED_GLOBS overrides for tests (space-separated globs, all 3way).
managed_globs() {
  if [ -n "${UPGRADE_MANAGED_GLOBS:-}" ]; then
    set -f
    for g in $UPGRADE_MANAGED_GLOBS; do printf '%s\t3way\n' "$g"; done
    set +f
    return
  fi
  cat <<'EOF'
ARBORETUM.md	3way
scripts/*.sh	3way
scripts/lib/*	3way
scripts/roadmap/*	3way
.claude/hooks/*	3way
.githooks/*	3way
docs/templates/*	3way
docs/definitions/*	3way
workflows/*	3way
EOF
}
# NOTE: root ARBORETUM.md is a same-path canonical framework contract, so it is
# managed directly. Narrative-file report-only (adopter root CLAUDE.md /
# PRINCIPLES.md / AGENTS.md) is deferred. Those files are *templated* at /init
# (docs/templates/<X> → root <X>),
# so a same-path glob compares the wrong files (root vs plugin-root, or
# template-vs-template). Correct reporting needs a target→source-template mapping;
# tracked as a follow-up. The `report-only` policy + cmd_plan branch are retained
# for when that mapping lands. (docs/templates/PRINCIPLES.md is already synced
# 3-way under `docs/templates/*`.)

resolve_plugin() {
  if [ -n "${UPGRADE_PLUGIN_ROOT:-}" ]; then printf '%s\ttest\n' "$UPGRADE_PLUGIN_ROOT"; return; fi
  discover_plugin_root || die "arboretum plugin not found in cache — run /plugin install arboretum"
}

# Emit, for each managed file (union of plugin + tree), a classification.
cmd_plan() {
  need_jq
  local pinfo proot; pinfo="$(resolve_plugin)"; proot="${pinfo%%	*}"
  # --plan is read-only: do NOT call manifest_init_if_missing here.
  # read_manifest_sha already returns empty when the manifest is absent (jq on
  # a missing file → empty), so classification still works with no manifest.
  local actions="{}" policy_map="{}"
  while IFS=$'\t' read -r glob policy; do
    # union of matches in plugin and in tree
    local rels; rels="$( { (cd "$proot" 2>/dev/null && compgen -G "$glob" || true);
                           (cd "$PROJECT_DIR" && compgen -G "$glob" || true); } | sort -u )"
    local rel
    for rel in $rels; do
      [ -z "$rel" ] && continue
      if is_excluded "$rel"; then
        if obsolete_removal_safe "$rel" "$proot"; then
          actions="$(echo "$actions" | jq --arg k "$rel" '. + {($k):"remove-obsolete"}')"
          policy_map="$(echo "$policy_map" | jq --arg k "$rel" '. + {($k):"obsolete"}')"
        fi
        continue
      fi
      local in_plugin=no in_tree=no base ours theirs action
      [ -f "$proot/$rel" ] && in_plugin=yes
      [ -f "$PROJECT_DIR/$rel" ] && in_tree=yes
      base="$(read_manifest_sha "$rel")"
      [ "$in_tree" = yes ]   && ours="$(sha "$PROJECT_DIR/$rel")"   || ours=""
      [ "$in_plugin" = yes ] && theirs="$(sha "$proot/$rel")"       || theirs=""
      if [ "$policy" = report-only ]; then
        if [ "$in_plugin" = yes ] && { [ "$theirs" != "$base" ] || [ "$ours" != "$base" ]; }; then
          action=report-only; else action=unchanged; fi
      else
        action="$(classify_file "$base" "$ours" "$theirs" "$in_plugin" "$in_tree")"
      fi
      [ "$action" = unchanged ] && continue
      actions="$(echo "$actions" | jq --arg k "$rel" --arg v "$action" '. + {($k):$v}')"
      policy_map="$(echo "$policy_map" | jq --arg k "$rel" --arg v "$policy" '. + {($k):$v}')"
    done
  done < <(managed_globs)
  # #407: removal detection diffs manifest-tracked files against the plugin. With
  # no baseline (empty/absent manifest) it has nothing to diff and is DISABLED —
  # report that as "inconclusive" rather than letting the caller imply "zero
  # removals". Read-only: jq on a missing manifest errors → treated as 0 tracked.
  local tracked removal_detection
  tracked="$(jq -r '.files | length' "$MANIFEST" 2>/dev/null || echo 0)"
  [ "${tracked:-0}" -gt 0 ] && removal_detection=active || removal_detection=inconclusive
  jq -n --argjson a "$actions" --argjson p "$policy_map" --arg root "$proot" \
        --arg rd "$removal_detection" \
        '{plugin_root:$root, actions:$a, policy:$p, removal_detection:$rd}'
}

plugin_version() { [ -n "${UPGRADE_PLUGIN_VERSION:-}" ] && { echo "$UPGRADE_PLUGIN_VERSION"; return; }
  local pinfo; pinfo="$(resolve_plugin)"; echo "${pinfo##*	}"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

bump_manifest_version() { need_jq; local v="$1" tmp; tmp="$(mktemp "$(dirname "$MANIFEST")/.manifest.XXXXXX")"
  jq --arg v "$v" --arg t "$(now_utc)" '.framework_version=$v | .updated_at=$t' "$MANIFEST" >"$tmp" && mv "$tmp" "$MANIFEST" || rm -f "$tmp"; }

# Additive settings allowlist merge — delegate to seed-settings.sh.
# seed-settings.sh takes two positional args: <target> <template>.
# It is self-guarding: degrades gracefully when jq is absent (exits 0).
merge_settings() { local proot="$1"
  local target="$PROJECT_DIR/.claude/settings.json"
  local template="$proot/docs/templates/settings.json.template"
  if [ -x "$HERE/seed-settings.sh" ] && [ -f "$template" ]; then
    bash "$HERE/seed-settings.sh" "$target" "$template" 2>/dev/null \
      || echo "upgrade-sync: settings merge skipped — merge allowlist manually from $template" >&2
  fi
}

cmd_apply() {
  need_jq
  local plan proot; plan="$(cmd_plan)"; proot="$(echo "$plan" | jq -r '.plugin_root')"
  local v; v="$(plugin_version)"
  manifest_init_if_missing
  ensure_arboretum_config
  # Apply only the non-interactive-safe actions here; conflicts/report-only are
  # surfaced by the skill and never auto-applied by the helper.
  while IFS=$'\t' read -r rel action; do
    case "$action" in
      add|overwrite-safe|overwrite-local|converged)
        if [ -f "$proot/$rel" ]; then
          mkdir -p "$PROJECT_DIR/$(dirname "$rel")"
          if cp "$proot/$rel" "$PROJECT_DIR/$rel"; then
            write_manifest_entry "$rel" "$v" "$(sha "$proot/$rel")"
          else
            echo "upgrade-sync: cp failed for $rel — base not recorded" >&2
          fi
        fi ;;
      remove-obsolete)
        if rm -f "$PROJECT_DIR/$rel"; then
          remove_manifest_entry "$rel"
        else
          echo "upgrade-sync: rm failed for $rel — obsolete file left in place" >&2
        fi ;;
    esac
  done < <(echo "$plan" | jq -r '.actions | to_entries[] | "\(.key)\t\(.value)"')
  merge_settings "$proot"
  # Only bump framework_version when no unresolved items remain (conflicts or
  # report-removed). Bumping while conflicts exist would suppress the staleness
  # nagging before the project is actually in sync.
  local unresolved
  unresolved=$(echo "$plan" | jq -r '[.actions[] | select(. == "conflict" or . == "report-removed")] | length')
  if [ "${unresolved:-0}" -eq 0 ]; then
    bump_manifest_version "$v"
  fi
  echo "$plan"   # emit the full plan so the skill can report conflicts/report-only
}

cmd_bootstrap() {
  need_jq; manifest_init_if_missing
  local pinfo proot v; pinfo="$(resolve_plugin)"; proot="${pinfo%%	*}"; v="$(plugin_version)"
  while IFS=$'\t' read -r glob policy; do
    [ "$policy" = 3way ] || continue
    local rels; rels="$(cd "$PROJECT_DIR" && compgen -G "$glob" || true)"
    local rel
    for rel in $rels; do
      is_excluded "$rel" && continue
      [ -f "$proot/$rel" ] || continue
      # Only record a base when tree == plugin; divergent files get NO base
      # entry, so the next --plan classifies them as overwrite-local (unknown
      # base + differs from plugin → plugin-wins under the #394 policy).
      if [ "$(sha "$PROJECT_DIR/$rel")" = "$(sha "$proot/$rel")" ]; then
        write_manifest_entry "$rel" "$v" "$(sha "$proot/$rel")"
      fi
    done
  done < <(managed_globs)
  bump_manifest_version "$v"
}

# --- dispatch -------------------------------------------------------------
main() {
  case "${1:-}" in
    --read-manifest-sha)     [ "$#" -ge 2 ] || die "usage: --read-manifest-sha <path>"; read_manifest_sha "$2" ;;
    --read-manifest-version) read_manifest_version ;;
    --write-manifest-entry)  [ "$#" -ge 4 ] || die "usage: --write-manifest-entry <path> <version> <sha>"; write_manifest_entry "$2" "$3" "$4" ;;
    --plan)    cmd_plan ;;
    --apply)   cmd_apply ;;
    --bootstrap-manifest) cmd_bootstrap ;;
    *) die "usage: upgrade-sync.sh --plan|--apply|--bootstrap-manifest" ;;
  esac
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
