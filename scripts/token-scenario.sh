#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ARBORETUM_MODE=testbed ARBORETUM_RUN_ID="${ARBORETUM_RUN_ID:-scenario}"
while [ $# -gt 0 ]; do case "$1" in
  --reads) IFS=: read -r doc section <<<"$2"
           bash "$ROOT/scripts/read-doc-section.sh" "$doc" "$section" >/dev/null 2>&1 || true
           shift 2;;
  *) shift;; esac; done
echo "scenario complete -> ${ARBORETUM_TOKEN_LEDGER:-.arboretum/token-ledger/scenario.jsonl}"
