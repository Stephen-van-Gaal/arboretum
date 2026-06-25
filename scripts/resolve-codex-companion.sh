#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# resolve-codex-companion.sh — print the absolute path to the installed codex
# plugin's codex-companion.mjs, resolved version-independently (#800).
#
# Scans plugin-cache manifests for the plugin whose declared "name" is "codex"
# (same content-based discovery as /start Step 5), then derives
# <plugin-root>/scripts/codex-companion.mjs. Highest cached version wins.
# Exit 1 with empty stdout when not found, so the reviewers.yml codex row
# degrades cleanly (section-dispatch "codex deferred").
set -euo pipefail

# jq is required to read the top-level plugin name. Guard explicitly so a missing
# jq surfaces a clear diagnostic (and still degrades the codex row cleanly via the
# non-zero exit) rather than masquerading as "companion not found".
command -v jq >/dev/null 2>&1 || {
  echo "resolve-codex-companion: jq not found (required to match the plugin name)" >&2
  exit 1
}

CACHE_ROOT="${ARBO_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}"

best=""
best_ver=""
while IFS= read -r manifest; do
  # Match the plugin's *top-level* declared name (not a nested author.name). A
  # line-oriented grep would also match "author": { "name": "codex" }, so parse
  # the JSON and test the top-level key with jq.
  jq -e '.name == "codex"' "$manifest" >/dev/null 2>&1 || continue
  root="$(cd "$(dirname "$manifest")/.." && pwd)"
  candidate="$root/scripts/codex-companion.mjs"
  [ -f "$candidate" ] || continue
  ver="$(basename "$root")"
  if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
    best="$candidate"
    best_ver="$ver"
  fi
done < <(find "$CACHE_ROOT" -type f -path '*/.claude-plugin/plugin.json' 2>/dev/null)

if [ -z "$best" ]; then
  echo "resolve-codex-companion: codex plugin companion not found under $CACHE_ROOT" >&2
  exit 1
fi
printf '%s\n' "$best"
