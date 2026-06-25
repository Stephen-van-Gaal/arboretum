#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# Unit smoke test for the shared arboretum state-dir resolver.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL state-dir: $1" >&2; exit 1; }

# shellcheck source=scripts/lib/state-dir.sh
source "$ROOT/scripts/lib/state-dir.sh"

# 1. Explicit override wins, verbatim, even inside a repo.
(
  cd "$ROOT"
  export ARBORETUM_STATE_DIR=/tmp/custom-store
  got="$(arboretum_state_dir)"
  [ "$got" = /tmp/custom-store ] || fail "override: expected /tmp/custom-store got $got"
)

# Throwaway main repo + a linked worktree off it.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
main="$work/main"; mkdir -p "$main"
git -C "$main" init -q
git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# Canonical physical path — the resolver returns pwd -P, so expectations must too.
main_real="$(cd "$main" && pwd -P)"

# 2. From the MAIN checkout → <main>/.arboretum
(
  cd "$main"; unset ARBORETUM_STATE_DIR
  got="$(arboretum_state_dir)"
  [ "$got" = "$main_real/.arboretum" ] || fail "main checkout: expected $main_real/.arboretum got $got"
)

# 3. From a LINKED WORKTREE → still the main checkout's store, NOT the worktree's.
wt="$work/wt"
git -C "$main" worktree add -q "$wt" -b wt-branch
(
  cd "$wt"; unset ARBORETUM_STATE_DIR
  got="$(arboretum_state_dir)"
  [ "$got" = "$main_real/.arboretum" ] || fail "worktree: expected main $main_real/.arboretum got $got"
)

# 3b. From a SUBDIR of the main checkout → still <main>/.arboretum.
sub="$main/scripts/deep"; mkdir -p "$sub"
(
  cd "$sub"; unset ARBORETUM_STATE_DIR
  got="$(arboretum_state_dir)"
  [ "$got" = "$main_real/.arboretum" ] || fail "subdir: expected $main_real/.arboretum got $got"
)

# 4. Outside any git repo → cwd-relative .arboretum (today's fallback preserved).
nogit="$work/nogit"; mkdir -p "$nogit"
(
  cd "$nogit"; unset ARBORETUM_STATE_DIR
  got="$(arboretum_state_dir)"
  [ "$got" = ".arboretum" ] || fail "non-repo: expected .arboretum got $got"
)

echo "PASS state-dir"
