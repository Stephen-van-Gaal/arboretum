#!/usr/bin/env bash
# owner: project-infrastructure
# refresh-update-cache.sh — Check if a newer arboretum plugin release is available.
#
# Scans the active plugin cache for the highest installed arboretum version,
# compares it against the latest GitHub release (stvangaal/arboretum),
# and writes the result to .arboretum/update-cache.json.
#
# Cache shape:
#   {
#     "fetched_at": "<ISO-8601 UTC>",
#     "installed_version": "<semver>" | null,
#     "latest_version":    "<semver>" | null,
#     "update_available":  true | false,
#     "error": null | "manifest-not-found" | "gh-unavailable"
#                       | "gh-call-failed" | "no-release"
#   }
#
# Usage:
#   bash scripts/refresh-update-cache.sh [project-dir]
#
# Exit codes:
#   0  — cache written (any state including errors)
#   1  — gh CLI not found
#
# Override the plugin cache root for tests:
#   ARBORETUM_PLUGIN_CACHE=/path/to/fake/cache bash scripts/refresh-update-cache.sh
#
# Safe for concurrent calls — writes use mktemp + atomic rename.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/update-cache.json"
if [ -n "${ARBORETUM_PLUGIN_CACHE:-}" ]; then
  PLUGIN_CACHE_ROOTS=("$ARBORETUM_PLUGIN_CACHE")
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${HOME}/.claude/plugins/cache" ]; then
  PLUGIN_CACHE_ROOTS=("${HOME}/.claude/plugins/cache")
elif [ -d "${HOME}/.codex/plugins/cache" ]; then
  PLUGIN_CACHE_ROOTS=("${HOME}/.codex/plugins/cache")
elif [ -d "${HOME}/.claude/plugins/cache" ]; then
  PLUGIN_CACHE_ROOTS=("${HOME}/.claude/plugins/cache")
else
  PLUGIN_CACHE_ROOTS=("${HOME}/.codex/plugins/cache")
fi

mkdir -p "$CACHE_DIR"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

write_cache() {
  local tmp
  tmp=$(mktemp "$CACHE_DIR/update-cache.json.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

# ── Find highest installed arboretum version ─────────────────────────
# Content-based matching on "name": "arboretum" in plugin.json; robust
# to marketplace namespaces that don't match the plugin name.

installed_version=$(
  for plugin_cache_root in "${PLUGIN_CACHE_ROOTS[@]}"; do
    [ -d "$plugin_cache_root" ] || continue
    find "$plugin_cache_root" -type f -name "plugin.json" 2>/dev/null
  done \
  | while IFS= read -r manifest; do
      if grep -q '"name"[[:space:]]*:[[:space:]]*"arboretum"' "$manifest" 2>/dev/null; then
        version=$(
          grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" 2>/dev/null \
            | head -1 \
            | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
            || true
        )
        if [ -n "$version" ]; then
          printf '%s\n' "$version"
        fi
      fi
    done \
  | sort -V | tail -1
) || true

if [ -z "$installed_version" ]; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "installed_version": null,
  "latest_version": null,
  "update_available": false,
  "error": "manifest-not-found"
}' "$(now_iso)")"
  exit 0
fi

# ── Detect gh ────────────────────────────────────────────────────────

if ! command -v gh >/dev/null 2>&1; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "installed_version": "%s",
  "latest_version": null,
  "update_available": false,
  "error": "gh-unavailable"
}' "$(now_iso)" "$installed_version")"
  exit 1
fi

# ── Fetch latest release ─────────────────────────────────────────────
# stvangaal/arboretum is public — no auth check needed.

gh_stderr=$(mktemp "$CACHE_DIR/gh.update.stderr.XXXXXX")
gh_exit=0
latest_raw=$(gh release view --repo stvangaal/arboretum \
    --json tagName --jq '.tagName' 2>"$gh_stderr") || gh_exit=$?

if [ "$gh_exit" -ne 0 ] || [ -z "$latest_raw" ]; then
  err_text=$(cat "$gh_stderr" 2>/dev/null || true)
  rm -f "$gh_stderr"
  if printf '%s' "$err_text" | grep -qiE 'release not found|no release'; then
    error_code="no-release"
  elif [ -z "$latest_raw" ] && [ "$gh_exit" -eq 0 ]; then
    error_code="no-release"
  else
    error_code="gh-call-failed"
  fi
  write_cache "$(printf '{
  "fetched_at": "%s",
  "installed_version": "%s",
  "latest_version": null,
  "update_available": false,
  "error": "%s"
}' "$(now_iso)" "$installed_version" "$error_code")"
  exit 0
fi
rm -f "$gh_stderr"

# Strip leading 'v' from tag (e.g. "v0.2.3" → "0.2.3")
latest_version="${latest_raw#v}"

# ── Compare versions ─────────────────────────────────────────────────
# sort -V puts the higher version last. Update is available when
# latest > installed (newest == latest and they differ).

update_available=false
newest=$(printf '%s\n' "$installed_version" "$latest_version" | sort -V | tail -1)
if [ "$newest" = "$latest_version" ] && [ "$installed_version" != "$latest_version" ]; then
  update_available=true
fi

write_cache "$(printf '{
  "fetched_at": "%s",
  "installed_version": "%s",
  "latest_version": "%s",
  "update_available": %s,
  "error": null
}' "$(now_iso)" "$installed_version" "$latest_version" "$update_available")"
exit 0
