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

# --- consolidate: migrate scattered worktree artifacts into the central store (#673) ---
(
  unset ARBORETUM_STATE_DIR   # exercise real git-anchored resolution, not the override
  w2="$(mktemp -d)"; main="$w2/main"; mkdir -p "$main"
  git -C "$main" init -q
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$main" worktree add -q "$w2/wt" -b wtb >/dev/null 2>&1
  wtj="$w2/wt/.arboretum/token-journey"; mkdir -p "$wtj"
  printf 'report A\n' > "$wtj/2026-06-07T100100Z-issue-641.md"
  wtl="$w2/wt/.arboretum/token-ledger"; mkdir -p "$wtl"
  printf '{"contributor":"reads","est_tokens":5}\n' > "$wtl/session.jsonl"
  # Physical path — the resolver canonicalizes via pwd -P, so expectations must too.
  main_real="$(cd "$main" && pwd -P)"; central="$main_real/.arboretum"

  # dry-run mutates nothing
  out="$(cd "$main" && bash "$ROOT/scripts/token-cleanup.sh" consolidate --dry-run)"
  [ -f "$wtj/2026-06-07T100100Z-issue-641.md" ] || fail "dry-run must not move journey file"
  [ -z "$(ls -A "$central/token-journey" 2>/dev/null || true)" ] || fail "dry-run must not populate central"
  grep -qi 'journey' <<<"$out" || fail "dry-run should list a planned journey move"

  # real run migrates into the main checkout's store and consumes the source
  out="$(cd "$main" && bash "$ROOT/scripts/token-cleanup.sh" consolidate)"
  [ -f "$central/token-journey/2026-06-07T100100Z-issue-641.md" ] || fail "journey not migrated to central"
  [ ! -f "$wtj/2026-06-07T100100Z-issue-641.md" ] || fail "source journey not consumed"
  grep -rq '"contributor":"reads"' "$central/token-ledger" || fail "ledger rows not migrated to central"
  rm -rf "$w2"
)

# --- consolidate: same-basename worktrees must not collide/lose rows (#673, Codex P1) ---
(
  unset ARBORETUM_STATE_DIR
  w3="$(mktemp -d)"; main="$w3/main"; mkdir -p "$main"
  git -C "$main" init -q
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # Two linked worktrees that share the basename "wt" under different parents.
  mkdir -p "$w3/a" "$w3/b"
  git -C "$main" worktree add -q "$w3/a/wt" -b wta >/dev/null 2>&1
  git -C "$main" worktree add -q "$w3/b/wt" -b wtb >/dev/null 2>&1
  mkdir -p "$w3/a/wt/.arboretum/token-ledger" "$w3/b/wt/.arboretum/token-ledger"
  printf '{"contributor":"reads","wt":"a"}\n' > "$w3/a/wt/.arboretum/token-ledger/session.jsonl"
  printf '{"contributor":"reads","wt":"b"}\n' > "$w3/b/wt/.arboretum/token-ledger/session.jsonl"
  central="$(cd "$main" && pwd -P)/.arboretum"
  (cd "$main" && bash "$ROOT/scripts/token-cleanup.sh" consolidate >/dev/null)
  # BOTH worktrees' rows must survive — basename collision must not drop either.
  grep -rqF '"wt":"a"' "$central/token-ledger" || fail "collision: worktree a's ledger rows lost"
  grep -rqF '"wt":"b"' "$central/token-ledger" || fail "collision: worktree b's ledger rows lost"
  rm -rf "$w3"
)

echo "PASS token-cleanup"
