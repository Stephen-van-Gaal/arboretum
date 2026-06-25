#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Device-stable base: anchors at the main checkout, not the invoking worktree (#673).
. "$ROOT/scripts/lib/state-dir.sh"

# consolidate — one-shot migration of token artifacts scattered across the repo's
# worktrees into the central store (#673, D28). The central store is
# `arboretum_state_dir` (the main checkout by default, or `$ARBORETUM_STATE_DIR`
# when overridden); worktree discovery comes from the CURRENT git repo, decoupled
# from where the store lives, so an absolute override still migrates correctly.
# Journey files move by their idempotent name (D20): an existing central copy
# wins; the source is dropped only when byte-identical (else preserved). Ledger
# files (live + archived) are preserved into the central archive under a name
# disambiguated by a hash of the worktree's full path, so two worktrees sharing a
# basename never collide — safer than row-merging into a possibly-active live
# ledger; all rows still land in one store. `--dry-run` lists planned moves and
# mutates nothing. Discovery is bounded to `git worktree list` (never an
# unbounded filesystem walk).
consolidate() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local central; central="$(arboretum_state_dir)"
  local moved_j=0 moved_l=0 line wt wt_phys
  # Worktree list from the current repo context, NOT from the store location.
  while IFS= read -r line; do
    case "$line" in worktree\ *) wt="${line#worktree }" ;; *) continue ;; esac
    [ -d "$wt" ] || continue
    wt_phys="$(cd "$wt" 2>/dev/null && pwd -P)" || continue
    # Skip the worktree whose own .arboretum IS the central store (can't move into itself).
    [ "$wt_phys/.arboretum" = "$central" ] && continue
    # Stable per-worktree disambiguator (full-path hash) — basenames can collide.
    local wtkey; wtkey="$(printf '%s' "$wt_phys" | cksum | cut -d' ' -f1)"
    # journey artifacts
    local src_j="$wt_phys/.arboretum/token-journey" f base tgt
    if [ -d "$src_j" ]; then
      for f in "$src_j"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"; tgt="$central/token-journey/$base"
        if [ "$dry" = 1 ]; then echo "  would move journey: $f -> $tgt"
        else
          mkdir -p "$central/token-journey"
          # Move when absent; on collision drop the source only if byte-identical,
          # else preserve it in place rather than silently lose it.
          if [ -e "$tgt" ]; then cmp -s "$f" "$tgt" && rm -f "$f"; else mv "$f" "$tgt"; fi
        fi
        moved_j=$((moved_j+1))
      done
    fi
    # ledger files (live + archive)
    local src_l="$wt_phys/.arboretum/token-ledger" lf rel ltgt
    if [ -d "$src_l" ]; then
      while IFS= read -r lf; do
        rel="${lf#"$src_l"/}"; rel="$(printf '%s' "$rel" | tr '/' '-')"
        ltgt="$central/token-ledger/archive/$wtkey-$rel"
        if [ "$dry" = 1 ]; then echo "  would move ledger: $lf -> $ltgt"
        else
          mkdir -p "$central/token-ledger/archive"
          # Disambiguated name means no cross-worktree collision; on a re-run
          # collision drop the source only if byte-identical, else preserve it.
          if [ -e "$ltgt" ]; then cmp -s "$lf" "$ltgt" && rm -f "$lf"; else mv "$lf" "$ltgt"; fi
        fi
        moved_l=$((moved_l+1))
      done < <(find "$src_l" -type f -name '*.jsonl' 2>/dev/null | LC_ALL=C sort)
    fi
  done < <(git worktree list --porcelain 2>/dev/null)
  local verb; [ "$dry" = 1 ] && verb="(dry-run) would consolidate" || verb="Consolidated"
  echo "$verb $moved_j journey + $moved_l ledger file(s) into $central"
}

if [ "${1:-}" = "consolidate" ]; then shift; consolidate "$@"; exit 0; fi

# Rotate per-session token-journey push ledgers (#721) — a third rotation target
# alongside token-ledger/ and token-journey/. Runs before the token-ledger
# report/early-exit below so a journey-only session (no spend ledger) is still
# pruned. Archive name carries the per-session basename, so two sessions rotated
# in the same second never collide. Prune to the last 20.
journey_led_dir="$(arboretum_state_dir)/token-journey-ledger"
if [ -d "$journey_led_dir" ]; then
  jarch="$journey_led_dir/archive"; mkdir -p "$jarch"
  for jf in "$journey_led_dir"/*.jsonl; do
    [ -f "$jf" ] || continue
    mv "$jf" "$jarch/$(basename "$jf" .jsonl)-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo rotated).jsonl"
  done
  ls -1t "$jarch"/*.jsonl 2>/dev/null | tail -n +21 | while IFS= read -r f; do rm -f "$f"; done
fi

led_dir="$(arboretum_state_dir)/token-ledger"
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
