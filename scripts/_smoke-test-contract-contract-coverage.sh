#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-contract-coverage.sh — Contract test for
# docs/contracts/contract-coverage.contract.md. Asserts CC-1..CC-7 from
# the contract's ## Test surface against scripts/generate-coverage.sh and
# scripts/validate-coverage-manifest.sh current behaviour.
#
# Fixture-project pattern: each case builds a mktemp -d skeleton with
# scripts/, .claude/hooks/, docs/contracts/, then runs the real coverage
# scripts against it with cwd set to the fixture root (both scripts derive
# their ROOT from $(pwd)). The scripts under test are the live ones in
# scripts/ — the fixture only supplies the surfaces they scan and the
# contracts they read.
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
#
# Closes #140 (arboretum should detect drift in its own artifacts) as
# non-recurrable by construction: CC-1 asserts the drift detector is
# itself covered. Any regression that drops the coverage scripts' rows or
# breaks the freshness/duplicate/strict invariants fails this test in CI.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-coverage.sh"
VALIDATOR="$SCRIPT_DIR/validate-coverage-manifest.sh"

[ -f "$GEN" ]       || { echo "FAIL: $GEN not found" >&2; exit 1; }
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

FIXTURES=()
new_fixture() {
  local d
  d=$(mktemp -d)
  FIXTURES+=("$d")
  mkdir -p "$d/scripts" "$d/.claude/hooks" "$d/docs/contracts"
  echo "$d"
}
cleanup() { for d in "${FIXTURES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# Write a full-shape contract owning the given script paths.
# Args: file, seam-name, script-path...
write_full_contract() {
  local file="$1" name="$2"; shift 2
  {
    echo "---"
    echo "seam: $name"
    echo "version: 1.0"
    echo "producer-type: script"
    echo "consumer-type: script"
    echo "owns:"
    local s
    for s in "$@"; do echo "  - $s"; done
    echo "---"
    echo "<!-- owner: pipeline-contracts-template -->"
    echo ""
    echo "# $name"
  } > "$file"
}

# Write a cli-shape contract for a single script.
# Args: file, seam-name, script-path
write_cli_contract() {
  {
    echo "---"
    echo "script: $3"
    echo "version: 1.0"
    echo "---"
    echo "<!-- owner: pipeline-contracts-template -->"
    echo ""
    echo "# $2"
  } > "$1"
}

# ── CC-1: self-coverage (the #140 meta-invariant) ────────────────────
# A contract owning the two coverage scripts flips both from MISSING to
# that contract — the drift detector is itself covered.
F=$(new_fixture)
: > "$F/scripts/generate-coverage.sh"
: > "$F/scripts/validate-coverage-manifest.sh"
write_full_contract "$F/docs/contracts/cov.contract.md" "contract-coverage" \
  "scripts/generate-coverage.sh" "scripts/validate-coverage-manifest.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
COV="$F/docs/contracts/_coverage.md"
if grep -qE '^\| scripts/generate-coverage\.sh \| docs/contracts/cov\.contract\.md \| full \|' "$COV" 2>/dev/null \
   && grep -qE '^\| scripts/validate-coverage-manifest\.sh \| docs/contracts/cov\.contract\.md \| full \|' "$COV" 2>/dev/null; then
  pass "CC-1: drift detector is self-covered (both coverage scripts map to their contract, not MISSING)"
else
  fail_case "CC-1: self-coverage flip failed" "$(cat "$COV" 2>/dev/null)"
fi

# ── CC-2: deterministic regen ────────────────────────────────────────
F=$(new_fixture)
: > "$F/scripts/foo.sh"
write_full_contract "$F/docs/contracts/foo.contract.md" "foo" "scripts/foo.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
cp "$F/docs/contracts/_coverage.md" "$F/first.md"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
if diff -q "$F/first.md" "$F/docs/contracts/_coverage.md" >/dev/null 2>&1; then
  pass "CC-2: deterministic regen — back-to-back runs are byte-identical"
else
  fail_case "CC-2: regen is not idempotent" "$(diff -u "$F/first.md" "$F/docs/contracts/_coverage.md" 2>&1 | head -30)"
fi

# ── CC-3: freshness-drift detection ──────────────────────────────────
# A cli-contract is present so the validator is past bootstrap and runs
# the real freshness diff.
F=$(new_fixture)
: > "$F/scripts/foo.sh"
write_cli_contract "$F/docs/contracts/bar.cli-contract.md" "bar" "scripts/foo.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
# Clean manifest passes.
out_clean=$( cd "$F" && bash "$VALIDATOR" 2>&1 ); rc_clean=$?
# Now corrupt the committed manifest with a row a fresh regen won't have.
echo "| scripts/bogus.sh | MISSING | — |" >> "$F/docs/contracts/_coverage.md"
out_drift=$( cd "$F" && bash "$VALIDATOR" 2>&1 ); rc_drift=$?
if [ "$rc_clean" -eq 0 ] && [ "$rc_drift" -ne 0 ] && echo "$out_drift" | grep -q "COVERAGE-MANIFEST-DRIFT"; then
  pass "CC-3: freshness-drift detection (clean passes, stale manifest fails with COVERAGE-MANIFEST-DRIFT)"
else
  fail_case "CC-3: drift detection wrong (clean rc=$rc_clean, drift rc=$rc_drift)" "clean: $out_clean
drift: $out_drift"
fi

# ── CC-4: read-only validation ───────────────────────────────────────
F=$(new_fixture)
: > "$F/scripts/foo.sh"
write_cli_contract "$F/docs/contracts/bar.cli-contract.md" "bar" "scripts/foo.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
COV="$F/docs/contracts/_coverage.md"
cp "$COV" "$F/before.md"
( cd "$F" && bash "$VALIDATOR" ) >/dev/null 2>&1
if diff -q "$F/before.md" "$COV" >/dev/null 2>&1; then
  pass "CC-4: validator is read-only (committed manifest byte-identical after run)"
else
  fail_case "CC-4: validator mutated the committed manifest" "$(diff -u "$F/before.md" "$COV" 2>&1 | head -20)"
fi

# ── CC-5: duplicate-ownership detection ──────────────────────────────
F=$(new_fixture)
: > "$F/scripts/foo.sh"
write_full_contract "$F/docs/contracts/a.contract.md" "a" "scripts/foo.sh"
write_full_contract "$F/docs/contracts/b.contract.md" "b" "scripts/foo.sh"
out_dup=$( cd "$F" && bash "$GEN" 2>&1 ); rc_dup=$?
if [ "$rc_dup" -ne 0 ] && echo "$out_dup" | grep -q "DUPLICATE-OWNERSHIP"; then
  pass "CC-5 (full+full): duplicate-ownership detection (generate-coverage exits non-zero)"
else
  fail_case "CC-5 (full+full): duplicate ownership not detected (rc=$rc_dup)" "$out_dup"
fi

# CC-5 (mixed shape): a full-shape contract and a cli-shape contract claiming
# the same surface must also be detected — the coverage parser shares one
# ownership map across both shapes, so this is the format combination the
# rollout actually exercises (full contracts + cli contracts side by side).
F=$(new_fixture)
: > "$F/scripts/foo.sh"
write_full_contract "$F/docs/contracts/a.contract.md" "a" "scripts/foo.sh"
write_cli_contract  "$F/docs/contracts/c.cli-contract.md" "c" "scripts/foo.sh"
out_dup_mixed=$( cd "$F" && bash "$GEN" 2>&1 ); rc_dup_mixed=$?
if [ "$rc_dup_mixed" -ne 0 ] && echo "$out_dup_mixed" | grep -q "DUPLICATE-OWNERSHIP"; then
  pass "CC-5 (full+cli): mixed-shape duplicate claim on the same surface is detected"
else
  fail_case "CC-5 (full+cli): mixed-shape duplicate not detected (rc=$rc_dup_mixed)" "$out_dup_mixed"
fi

# ── CC-6: strict-mode completeness ───────────────────────────────────
# Post-PR-7b re-tightening: the ramp escape branch is gone. A MISSING row —
# now only reachable as a regression (a new uncovered governance surface) —
# must fail non-zero with COVERAGE-MANIFEST-INCOMPLETE, not pass with a
# warning. This is the inverse of the pre-7b ramp-mode behaviour CC-6 used
# to assert; the rollout-window ramp tier was removed once MISSING hit zero.
F=$(new_fixture)
: > "$F/scripts/foo.sh"        # covered by bar.cli-contract
: > "$F/scripts/uncovered.sh"  # no covering contract → MISSING (regression)
write_cli_contract "$F/docs/contracts/bar.cli-contract.md" "bar" "scripts/foo.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
out_strict=$( cd "$F" && bash "$VALIDATOR" 2>&1 ); rc_strict=$?
if [ "$rc_strict" -ne 0 ] \
   && echo "$out_strict" | grep -qF "COVERAGE-MANIFEST-INCOMPLETE"; then
  pass "CC-6: strict mode — a MISSING row fails non-zero with COVERAGE-MANIFEST-INCOMPLETE (no ramp escape)"
else
  fail_case "CC-6: strict-mode regression gate did not fire (rc=$rc_strict; expected non-zero + COVERAGE-MANIFEST-INCOMPLETE)" "$out_strict"
fi

# ── CC-7: scan-scope exclusion ───────────────────────────────────────
# Surfaces under a _* path component get no manifest row.
F=$(new_fixture)
: > "$F/scripts/foo.sh"
: > "$F/scripts/_smoke-test-foo.sh"
mkdir -p "$F/scripts/_archived"
: > "$F/scripts/_archived/bar.sh"
write_full_contract "$F/docs/contracts/foo.contract.md" "foo" "scripts/foo.sh"
( cd "$F" && bash "$GEN" ) >/dev/null 2>&1
COV="$F/docs/contracts/_coverage.md"
# Positive guard first: a failed/empty generator would make a missing _coverage.md
# satisfy both negative greps vacuously (grep on an absent file returns non-zero),
# reporting a false PASS. Require the manifest to exist and contain the
# *included* surface before asserting the excluded ones are absent.
if [ -f "$COV" ] && grep -q "scripts/foo.sh" "$COV" 2>/dev/null \
   && ! grep -q "_smoke-test-foo.sh" "$COV" 2>/dev/null \
   && ! grep -q "_archived/bar.sh" "$COV" 2>/dev/null; then
  pass "CC-7: scan-scope exclusion — manifest generated with scripts/foo.sh; _* components get no row"
else
  fail_case "CC-7: scan-scope exclusion failed (manifest missing scripts/foo.sh, or excluded paths leaked)" "$(cat "$COV" 2>/dev/null || echo '(no _coverage.md produced)')"
fi

# ── Summary ──────────────────────────────────────────────────────────
if [ $fail -eq 0 ]; then
  echo "All contract-coverage contract assertions passed (CC-1..CC-7)."
  exit 0
else
  echo "contract-coverage contract test FAILED" >&2
  exit 1
fi
