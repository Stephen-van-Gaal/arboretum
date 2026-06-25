#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-ledger: $1" >&2; exit 1; }

ARBORETUM_TOKEN_LEDGER="$(mktemp)"; export ARBORETUM_TOKEN_LEDGER
trap 'rm -f "$ARBORETUM_TOKEN_LEDGER"' EXIT
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/token-ledger.sh"

# control char + chars/4: 12-byte source with an embedded NUL must scrub and count
ledger_append reads "foo.md@$(printf 'a\002b')" 12

row="$(tail -1 "$ARBORETUM_TOKEN_LEDGER")"
command -v jq >/dev/null || fail "jq required"
[ "$(jq -r .contributor <<<"$row")" = reads ] || fail "contributor field"
[ "$(jq -r .bytes <<<"$row")" = 12 ]           || fail "bytes field"
[ "$(jq -r .est_tokens <<<"$row")" = 3 ]        || fail "chars/4 estimate (12/4=3)"
[ "$(jq -r .source <<<"$row")" = "foo.md@ab" ]  || fail "control char not scrubbed"
# schema: required keys present (the seam — pin them)
for k in run_id ts workflow stage contributor bucket source bytes est_tokens; do
  jq -e "has(\"$k\")" <<<"$row" >/dev/null || fail "schema missing key: $k"
done

source "$ROOT/scripts/lib/token-rates.sh"
ledger_append model "step:plan-3" 4000 claude-sonnet-4-6
mrow="$(tail -1 "$ARBORETUM_TOKEN_LEDGER")"
[ "$(jq -r .model <<<"$mrow")" = claude-sonnet-4-6 ] || fail "model field"
# est_cost = est_tokens(1000) * sonnet input 3.00 / 1e6 = 0.003
[ "$(jq -r .est_cost <<<"$mrow")" = 0.003 ] || fail "est_cost from rate table"
echo "PASS token-ledger"
