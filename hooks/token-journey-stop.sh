#!/usr/bin/env bash
# owner: token-accounting
# token-journey-stop.sh — Claude Code `Stop` hook (plugin-provided).
# Per-message push capture: append rows for assistant messages since the ledger
# watermark, tagged with the authoritative active stage. Non-blocking: never
# blocks a turn (|| true semantics), gated on the ledger lib + the enabled
# config. (epic #719 D6/D7, slice-1 DS1.2.)
set -uo pipefail

# Read the hook payload from stdin; pull session_id + transcript_path without a
# jq/python dependency so the per-turn cost stays a couple of shell builtins.
input=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)
tx=$(printf '%s' "$input" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)
[ -n "$tx" ] && [ -f "$tx" ] || exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
lib="$ROOT/scripts/lib/token-journey-ledger.sh"
[ -f "$lib" ] || exit 0
# shellcheck source=/dev/null
. "$lib" || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Anchor to the project root so the shared ledger-path resolver
# (arboretum_state_dir, which reads the cwd's git context) lands the ledger under
# THIS project's .arboretum even when the session cwd is elsewhere (Codex P2).
# The absolute paths below (transcript, ROOT, cache) are unaffected by the cd.
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# enabled gate (governs auto-generation only; the hand path is always runnable).
# Parse the exact `enabled=` line — a substring match would treat a config like
# `output_dir: /tmp/enabled=true` as enabled even with `enabled: false` (Codex P3).
cfg="$(bash "$ROOT/scripts/read-token-journey-config.sh" "$PROJECT_DIR/.arboretum.yml" 2>/dev/null || echo 'enabled=false')"
enabled="$(printf '%s\n' "$cfg" | sed -nE 's/^enabled=(.*)$/\1/p' | head -n1)"
[ "$enabled" = true ] || exit 0

# Authoritative stage from active-stage-cache.json (DS1.2). Falls back to
# (unknown-stage) — capture still proceeds; cost is never dropped.
cache="$PROJECT_DIR/.arboretum/active-stage-cache.json"
stage=""
if [ -f "$cache" ] && command -v jq >/dev/null 2>&1; then
  stage="$(jq -r '.stage // empty' "$cache" 2>/dev/null | sed 's#^/##')"
fi
[ -n "$stage" ] || stage="(unknown-stage)"

ledger="$(journey_ledger_path "${sid:-session}")"
journey_ledger_capture "$tx" "$ledger" --stage "$stage" || true
exit 0
