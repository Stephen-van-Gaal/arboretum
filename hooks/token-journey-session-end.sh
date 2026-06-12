#!/usr/bin/env bash
# owner: token-accounting
# token-journey-session-end.sh — Claude Code `SessionEnd` hook (plugin-provided).
# Render the per-session push ledger through the shared renderer at session end.
# Non-blocking: never blocks session exit (|| true), gated on the lib/driver +
# the enabled config. A missed render (hard kill) is recoverable by hand against
# the durable ledger (slice-1 DS1.5/DS1.6).
set -uo pipefail

input=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)

ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
lib="$ROOT/scripts/lib/token-journey-ledger.sh"
drv="$ROOT/scripts/render-ledger-journey.sh"
[ -f "$lib" ] && [ -f "$drv" ] || exit 0
# shellcheck source=/dev/null
. "$lib" || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Anchor to the project root so the ledger-path resolver finds THIS project's
# ledger even when the session cwd is elsewhere (Codex P2). The config reader,
# spawned below, also inherits this cwd so its default output_dir is correct.
cd "$PROJECT_DIR" 2>/dev/null || exit 0
cfg="$(bash "$ROOT/scripts/read-token-journey-config.sh" "$PROJECT_DIR/.arboretum.yml" 2>/dev/null || echo 'enabled=false')"
# Exact `enabled=` line, not a substring match (Codex P3).
enabled="$(printf '%s\n' "$cfg" | sed -nE 's/^enabled=(.*)$/\1/p' | head -n1)"
[ "$enabled" = true ] || exit 0
fmt="$(printf '%s\n' "$cfg" | sed -nE 's/^format=(.*)$/\1/p' | head -n1)"; [ -n "$fmt" ] || fmt=md
# Honor the configured output_dir (Codex P2) so the auto report lands where the
# manual token-report.sh journey path would. The reader always emits an
# output_dir (explicit value, else the device-stable default), so pass it through.
outdir="$(printf '%s\n' "$cfg" | sed -nE 's/^output_dir=(.*)$/\1/p' | head -n1)"

ledger="$(journey_ledger_path "${sid:-session}")"
[ -f "$ledger" ] || exit 0
if [ -n "$outdir" ]; then
  bash "$drv" --ledger "$ledger" --format "$fmt" --output-dir "$outdir" || true
else
  bash "$drv" --ledger "$ledger" --format "$fmt" || true
fi
exit 0
