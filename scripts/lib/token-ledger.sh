#!/usr/bin/env bash
# owner: token-accounting
# Append-only per-contributor token ledger. Source me; call ledger_append.
# Dependency-free except jq (already a project dependency).

# Device-stable base resolver, sourced once at load (not per-call) — anchors at
# the main checkout, not the invoking worktree (#673).
. "$(dirname "${BASH_SOURCE[0]}")/state-dir.sh"

_token_ledger_path() {
  if [ -n "${ARBORETUM_TOKEN_LEDGER:-}" ]; then printf '%s' "$ARBORETUM_TOKEN_LEDGER"; return; fi
  local dir; dir="$(arboretum_state_dir)/token-ledger"
  mkdir -p "$dir"
  printf '%s/%s.jsonl' "$dir" "${ARBORETUM_RUN_ID:-session}"
}

# scrub ASCII control chars (defense in depth — source ids are author-influenced)
_token_scrub() { printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177'; }

# ledger_append <contributor> <source> <bytes> [model] [est_cost]
ledger_append() {
  local contributor="$1" source bytes="$3" model="${4:-}" est_cost="${5:-}"
  source="$(_token_scrub "$2")"
  local est_tokens=$(( bytes / 4 ))   # chars/4 heuristic (D2); swap to a tokenizer later, same field
  if [ -n "$model" ] && [ -z "$est_cost" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/token-rates.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/token-rates.sh"
    local rate; rate="$(token_rate "$model" input)"
    est_cost="$(awk -v t="$est_tokens" -v r="$rate" 'BEGIN{printf "%g", t*r/1000000}')"
  fi
  jq -nc \
    --arg run "${ARBORETUM_RUN_ID:-session}" --arg ts "${ARBORETUM_TS:-}" \
    --arg wf "${ARBORETUM_WF:-}" --arg stage "${ARBORETUM_STAGE:-}" \
    --arg issue "${ARBORETUM_ISSUE:-}" --arg sha "$(git rev-parse --short HEAD 2>/dev/null || echo '')" \
    --arg mode "${ARBORETUM_MODE:-live}" --arg c "$contributor" \
    --arg bucket "${ARBORETUM_BUCKET:-on-demand}" --arg src "$source" \
    --argjson bytes "$bytes" --argjson tok "$est_tokens" \
    --arg model "$model" --arg cost "$est_cost" \
    '{run_id:$run, ts:$ts, workflow:$wf, stage:$stage, issue:$issue, git_sha:$sha,
      mode:$mode, contributor:$c, bucket:$bucket, source:$src, bytes:$bytes,
      est_tokens:$tok} + (if $model=="" then {} else {model:$model} end)
       + (if $cost=="" then {} else {est_cost:($cost|tonumber)} end)' \
    >> "$(_token_ledger_path)"
}
