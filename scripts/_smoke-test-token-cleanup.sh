#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-cleanup: $1" >&2; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export ARBORETUM_STATE_DIR="$work/.arboretum"
led="$ARBORETUM_STATE_DIR/token-ledger"; mkdir -p "$led"
printf '{"contributor":"reads","est_tokens":1200}\n{"contributor":"runtime","est_tokens":900}\n' > "$led/session.jsonl"

out="$(ARBORETUM_RUN_ID=session bash "$ROOT/scripts/token-cleanup.sh")"
grep -q 'reads' <<<"$out"   || fail "did not print token summary"
[ ! -f "$led/session.jsonl" ] || fail "ledger not rotated out of the live path"
ls "$led"/archive/*.jsonl >/dev/null 2>&1 || fail "ledger not archived"
echo "PASS token-cleanup"
