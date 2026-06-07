#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
led_dir="${ARBORETUM_STATE_DIR:-.arboretum}/token-ledger"
run="${ARBORETUM_RUN_ID:-session}"
ledger="$led_dir/$run.jsonl"
[ -f "$ledger" ] || { echo "(no token ledger for run '$run' — nothing to report)"; exit 0; }

echo "Token accounting — this cycle (est., advisory):"
bash "$ROOT/scripts/token-report.sh" diagnose --ledger "$ledger" || true
# billed + bust capture when a transcript is available (live cycles)
if [ -n "${ARBORETUM_TRANSCRIPT:-}" ] && [ -f "$ARBORETUM_TRANSCRIPT" ]; then
  echo "Cache / billed:"; bash "$ROOT/scripts/token-report.sh" billed || true
  echo "Cache-bust events:"; bash "$ROOT/scripts/token-report.sh" busts --transcript "$ARBORETUM_TRANSCRIPT" || true
fi

# rotate: move the live ledger to archive/, prune to the last 20
arch="$led_dir/archive"; mkdir -p "$arch"
mv "$ledger" "$arch/$run-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo rotated).jsonl"
# Prune to the last 20 archives. A `while read` loop is portable (xargs -r is a
# GNU-only extension) and safe for paths with whitespace; empty input is a no-op.
ls -1t "$arch"/*.jsonl 2>/dev/null | tail -n +21 | while IFS= read -r f; do rm -f "$f"; done
echo "(ledger rotated to $arch; live path cleared)"
