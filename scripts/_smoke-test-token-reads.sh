#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# ci-parallel: safe
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-reads: $1" >&2; exit 1; }
ARBORETUM_TOKEN_LEDGER="$(mktemp)"; export ARBORETUM_TOKEN_LEDGER; trap 'rm -f "$ARBORETUM_TOKEN_LEDGER"' EXIT

bash "$ROOT/scripts/read-doc-section.sh" docs/REGISTER.md "Spec Index" >/dev/null 2>&1 || true
grep -q '"contributor":"reads"' "$ARBORETUM_TOKEN_LEDGER" || fail "no reads row appended"
out="$(bash "$ROOT/scripts/token-report.sh" diagnose --ledger "$ARBORETUM_TOKEN_LEDGER")"
grep -q 'reads' <<<"$out" || fail "diagnose missing reads contributor"

sc="$(mktemp)"
ARBORETUM_TOKEN_LEDGER="$sc" bash "$ROOT/scripts/token-scenario.sh" --reads docs/REGISTER.md:"Spec Index" >/dev/null 2>&1 || true
grep -q '"mode":"testbed"' "$sc" || { rm -f "$sc"; fail "scenario did not tag mode:testbed"; }
rm -f "$sc"
echo "PASS token-reads"
