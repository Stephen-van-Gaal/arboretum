#!/usr/bin/env bash
# owner: pipeline-contracts-template
# validate-coverage-manifest.sh — Verify docs/contracts/_coverage.md is
# both fresh (matches a fresh generate-coverage.sh run) and complete
# (every script/hook in scope has a row). Peer to validate-cross-refs.sh.
#
# Read-only: regenerates into an isolated temp directory; never modifies
# the committed _coverage.md.
#
# Invoked from ci-checks.sh via the `=== Contract coverage validation ===`
# line. Per WS5 design §D5/§D6.

set -uo pipefail
ROOT="$(pwd)"
GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generate-coverage.sh"
GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$ROOT/docs/contracts"
COMMITTED="$CONTRACTS_DIR/_coverage.md"

[ -x "$GEN" ]       || { echo "validate-coverage-manifest: $GEN not executable" >&2; exit 1; }

is_plugin_manifest_root() {
  [ -f "$ROOT/.claude-plugin/plugin.json" ] \
    || [ -f "$ROOT/.codex-plugin/plugin.json" ]
}

# Bootstrap state — allowed only when docs/contracts/ has zero CLI-contract files.
# WS5 introduces *.cli-contract.md; pre-WS5 seam contracts (e.g. WS3b's
# s2/s3/s9) shipped under *.contract.md without owns: lists for governance
# scripts, so they're correctly ignored for coverage purposes. Bootstrap mode
# applies until WS5's first cli-contract lands (PR 2). Once any cli-contract
# exists, bootstrap is structurally unreachable: deleting all rows from
# _coverage.md cannot re-enter it, because the cli-contract file remains on
# disk.
if [ ! -d "$CONTRACTS_DIR" ]; then
  if is_plugin_manifest_root; then
    echo "validate-coverage-manifest: $CONTRACTS_DIR missing in plugin manifest root" >&2
    exit 1
  fi
  echo "validate-coverage-manifest: bootstrap state — docs/contracts/ not found; no cli-contracts to validate" >&2
  exit 0
fi

cli_contract_count=$(find "$CONTRACTS_DIR" -maxdepth 1 -type f \
                       -name '*.cli-contract.md' 2>/dev/null | wc -l)
cli_contract_count=$(echo "$cli_contract_count" | tr -d ' ')
if [ "$cli_contract_count" -eq 0 ]; then
  echo "validate-coverage-manifest: bootstrap state — no cli-contracts in docs/contracts/ (PR-1 of WS5 only)" >&2
  exit 0
fi

[ -f "$COMMITTED" ] || { echo "validate-coverage-manifest: $COMMITTED missing" >&2; exit 1; }

# Build an isolated mirror layout in a temp dir so the regenerator's writes
# stay sandboxed. The `scripts/` and `.claude/` directories are symlinked
# (mapping the temp paths to the real ones); contract files are copied so the
# regenerator parses them but writes the fresh manifest into the temp dir.
# generate-coverage.sh is placed at $tmp/_regen.sh (outside the scanned
# scripts/ tree) so its presence does not pollute the coverage table.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/docs/contracts"
# IMPORTANT: do NOT pre-mkdir $tmp/scripts or $tmp/.claude — `ln -s SRC DST`
# where DST already exists as a directory creates a nested symlink inside
# DST instead of mapping DST itself. Each ln-or-copy must operate on a
# nonexistent DST.
ln -s "$ROOT/scripts" "$tmp/scripts" 2>/dev/null || cp -R "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/.claude" "$tmp/.claude" 2>/dev/null || cp -R "$ROOT/.claude" "$tmp/.claude"
cp "$ROOT"/docs/contracts/*.contract.md      "$tmp/docs/contracts/" 2>/dev/null || true
cp "$ROOT"/docs/contracts/*.cli-contract.md  "$tmp/docs/contracts/" 2>/dev/null || true
# Place the regenerator outside the scanned scripts/ tree so it does not
# create a spurious MISSING row in the fresh manifest.
cp "$GEN" "$tmp/_regen.sh"
if [ -f "$GEN_DIR/lib/yaml-lite.sh" ]; then
  mkdir -p "$tmp/lib"
  cp "$GEN_DIR/lib/yaml-lite.sh" "$tmp/lib/yaml-lite.sh"
fi

# generate-coverage.sh uses $(pwd) as ROOT, so we invoke it from $tmp so
# it scans $tmp/scripts and $tmp/.claude/hooks and writes
# $tmp/docs/contracts/_coverage.md.
# Capture generator exit code explicitly (not via $? after `if !`, which
# reports the negated test status, not the generator's actual code).
( cd "$tmp" && bash _regen.sh )
gen_rc=$?
if [ "$gen_rc" -ne 0 ]; then
  echo "validate-coverage-manifest: generate-coverage.sh failed (exit $gen_rc)" >&2
  exit 1
fi

fresh="$tmp/docs/contracts/_coverage.md"
if ! diff -q "$COMMITTED" "$fresh" >/dev/null; then
  echo "COVERAGE-MANIFEST-DRIFT: $COMMITTED differs from a fresh generate-coverage.sh run" >&2
  echo "  Fix: bash scripts/generate-coverage.sh" >&2
  diff -u "$COMMITTED" "$fresh" | head -50 >&2
  exit 1
fi

# Strict mode (post-PR-7b re-tightening): no MISSING rows permitted. The
# WS5 rollout's ramp tier — which exited 0 with a warning while sweep PRs
# 6 / 7a / 7b were still populating the manifest — was removed once MISSING
# hit zero (the re-tightening event the contract-coverage contract pins to
# PR 7b). From here on, a MISSING row can only be a regression (a new
# uncovered governance surface), and it fails the build.
if grep -q "| MISSING |" "$COMMITTED"; then
  echo "COVERAGE-MANIFEST-INCOMPLETE: at least one script/hook has no covering contract" >&2
  grep "| MISSING |" "$COMMITTED" | sed 's/^/  /' >&2
  exit 1
fi

exit 0
