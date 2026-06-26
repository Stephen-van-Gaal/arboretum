#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# Smoke test for docs/contracts/web-setup.cli-contract.md.
# Exercises WS-1..WS-3 (the deterministic gate + exit-0 invariants) by driving
# the hook directly with controlled env and a fixture project dir. The active
# install path (WS-4) is out of scope — it needs the claude CLI and mutates
# ~/.claude — so this test only asserts the side-effect-free gate no-ops.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/web-setup.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

fail=0

# Each case runs the hook against a throwaway CLAUDE_PROJECT_DIR so the real
# repo is never touched and any staging dir is observable in isolation.
make_project() {
  # $1: dogfood value to write ("true", "false", or "" to omit the key)
  local dir; dir="$(mktemp -d)"
  if [ -n "${1:-}" ]; then
    printf 'layer: 0\ndogfood: %s\n' "$1" > "$dir/.arboretum.yml"
  else
    printf 'layer: 0\n' > "$dir/.arboretum.yml"
  fi
  printf '%s\n' "$dir"
}

# ── WS-1: remote-unset gate → exit 0, no output, no staging dir ──────
dir="$(make_project true)"
out="$(env -u CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" 2>/tmp/ws_err)"; rc=$?
err="$(cat /tmp/ws_err)"; rm -f /tmp/ws_err
if [ "$rc" -ne 0 ]; then echo "FAIL: WS-1 expected exit 0, got $rc" >&2; fail=1; fi
if [ -n "$out" ]; then echo "FAIL: WS-1 expected empty stdout, got: $out" >&2; fail=1; fi
if [ -n "$err" ]; then echo "FAIL: WS-1 expected empty stderr, got: $err" >&2; fail=1; fi
if [ -e "$dir/.arboretum/web-plugin" ]; then echo "FAIL: WS-1 staging dir created on remote-unset gate" >&2; fail=1; fi
[ "$fail" = 0 ] && echo "PASS: WS-1 remote-unset gate is a silent exit-0 no-op"
rm -rf "$dir"

# ── WS-2: dogfood-absent gate → exit 0, no output, no staging dir ────
for df in "" "false"; do
  dir="$(make_project "$df")"
  out="$(CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" 2>/dev/null)"; rc=$?
  label="${df:-<absent>}"
  if [ "$rc" -ne 0 ]; then echo "FAIL: WS-2 (dogfood=$label) expected exit 0, got $rc" >&2; fail=1; fi
  if [ -n "$out" ]; then echo "FAIL: WS-2 (dogfood=$label) expected empty stdout, got: $out" >&2; fail=1; fi
  if [ -e "$dir/.arboretum/web-plugin" ]; then echo "FAIL: WS-2 (dogfood=$label) staging dir created" >&2; fail=1; fi
  rm -rf "$dir"
done
[ "$fail" = 0 ] && echo "PASS: WS-2 dogfood-absent/false gate is a silent exit-0 no-op"

# WS-3 (exit-0 invariant) is asserted by the rc checks in WS-1 and WS-2.

if [ "$fail" = 0 ]; then
  echo "web-setup contract: ALL PASS"
else
  exit 1
fi
