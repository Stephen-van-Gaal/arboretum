#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# seed-settings.sh — seed or merge a project's .claude/settings.json permission
# allow list from the arboretum settings template.
#
# Usage: seed-settings.sh <target-settings.json> <template-settings.json>
#
#   target absent  → template copied verbatim.
#   target present → template's permissions.allow entries not already in the
#                     target are appended; the target's hooks, existing allow
#                     entries, and entry order are preserved untouched.
#
# `// []` defaults both allow lists so a hooks-only target (no `permissions`
# key — the common freshly-/init-ed case) never throws `array - null`.
#
# Requires jq for the merge path. If jq is absent the script prints a loud,
# actionable message and exits 0 — it never silently corrupts settings.json.

set -euo pipefail

TARGET="${1:?usage: seed-settings.sh <target> <template>}"
TEMPLATE="${2:?usage: seed-settings.sh <target> <template>}"

if [ ! -f "$TEMPLATE" ]; then
  echo "[seed-settings] template not found: $TEMPLATE" >&2
  exit 1
fi

if [ ! -f "$TARGET" ]; then
  cp "$TEMPLATE" "$TARGET"
  echo "[seed-settings] created: $TARGET"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[seed-settings] jq not found — skipping settings.json allow-list merge." >&2
  echo "[seed-settings] Add entries manually from: $TEMPLATE" >&2
  exit 0
fi

MERGED="$(jq -s '
  (.[0].permissions.allow // []) as $existing |
  (.[1].permissions.allow // []) as $new |
  .[0] | .permissions.allow = ($existing + ($new - $existing))
' "$TARGET" "$TEMPLATE")"

# Write atomically: stage to a temp file in the same directory, then mv it
# into place. A bare `> "$TARGET"` truncates first and can leave settings.json
# corrupt if the write is interrupted (signal, disk-full, crash).
TMP="$(mktemp "$(dirname "$TARGET")/.settings-seed.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$MERGED" > "$TMP"
mv "$TMP" "$TARGET"
echo "[seed-settings] merged allow list into: $TARGET"
