#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# Integration smoke test (#673): token-journey + token-ledger writes invoked from
# inside a LINKED WORKTREE must land in the MAIN checkout's .arboretum/ store,
# not the worktree's own — the cross-surface guard for the centralization change.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL token-artifact-centralization: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
main="$work/main"; mkdir -p "$main"
git -C "$main" init -q
git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$main" worktree add -q "$work/wt" -b wtb >/dev/null 2>&1
main_real="$(cd "$main" && pwd -P)"

# --- ledger: append from the worktree, assert the row lands in the main store ---
(
  cd "$work/wt"
  unset ARBORETUM_TOKEN_LEDGER ARBORETUM_STATE_DIR
  # shellcheck source=scripts/lib/token-ledger.sh
  source "$ROOT/scripts/lib/token-ledger.sh"
  ledger_append reads "src.md" 40
)
[ -n "$(ls -A "$main_real/.arboretum/token-ledger" 2>/dev/null || true)" ] \
  || fail "ledger row did not land in the main checkout's store"
[ ! -d "$work/wt/.arboretum/token-ledger" ] \
  || fail "ledger wrote into the worktree's own .arboretum (should be main's)"

# --- journey: run from the worktree with no --output-dir; artifact → main store ---
tx="$work/sess-xyz.jsonl"
cat > "$tx" <<'JSONL'
{"uuid":"u1","timestamp":"2026-06-07T10:00:00Z","message":{"id":"m1","model":"claude-opus-4","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"arboretum:design"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
JSONL
(
  cd "$work/wt"
  unset ARBORETUM_STATE_DIR ARBORETUM_TOKEN_JOURNEY_DIR
  bash "$ROOT/scripts/read-session-journey.sh" --transcript "$tx" >/dev/null
)
ls "$main_real/.arboretum/token-journey/"*.md >/dev/null 2>&1 \
  || fail "journey artifact did not land in the main checkout's store"
[ ! -d "$work/wt/.arboretum/token-journey" ] \
  || fail "journey wrote into the worktree's own .arboretum (should be main's)"

echo "PASS token-artifact-centralization"
