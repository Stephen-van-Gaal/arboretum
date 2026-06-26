#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-roadmap-install-labels.sh — Contract smoke test for
# docs/contracts/roadmap-install-labels.cli-contract.md. Asserts CLI-1..CLI-5
# fully offline: all assertions use --dry-run mode or a stripped-PATH live
# invocation — no gh calls, no network, no GitHub repo required.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/roadmap/install-labels.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: $INSTALLER not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# Shared fixture config so dry-run assertions are isolated from the CWD: run
# from the repo root, install-labels.sh finds the real roadmap.config.yaml and
# stays quiet, but from a config-less dir it prints "Note: ... not found" to
# stderr — which would break CLI-1's no-stderr invariant. Passing --config
# pins behaviour to the fixture regardless of where the test runs.
SHARED_CONFIG="$TMP/roadmap.config.yaml"
printf 'component_values:\n  - framework\naudience_values:\n  - developer\n' > "$SHARED_CONFIG"

# ---------------------------------------------------------------------------
# CLI-1: --dry-run emits the framework-fixed label families.
# Verifies that the three required family prefixes (type:, horizon:, appetite:)
# are present in the TSV output, and that the script exits 0 with no stderr.
# Fully offline: --dry-run bypasses gh entirely. --config pins the no-stderr
# invariant to the fixture (CWD-independent — see SHARED_CONFIG note above).
# ---------------------------------------------------------------------------
stdout_1="$TMP/cli1.out"
stderr_1="$TMP/cli1.err"
bash "$INSTALLER" --dry-run --config "$SHARED_CONFIG" >"$stdout_1" 2>"$stderr_1"; rc1=$?

if [ "$rc1" -ne 0 ]; then
  fail_case "CLI-1" "exit $rc1 (expected 0); stderr: $(cat "$stderr_1")"
elif [ -s "$stderr_1" ]; then
  fail_case "CLI-1" "unexpected stderr: $(cat "$stderr_1")"
elif ! grep -q $'^type:' "$stdout_1"; then
  fail_case "CLI-1" "no type:* label found in --dry-run output"
elif ! grep -q $'^horizon:' "$stdout_1"; then
  fail_case "CLI-1" "no horizon:* label found in --dry-run output"
elif ! grep -q $'^appetite:' "$stdout_1"; then
  fail_case "CLI-1" "no appetite:* label found in --dry-run output"
else
  pass "CLI-1: --dry-run exits 0, framework-fixed families present (type:, horizon:, appetite:)"
fi

# ---------------------------------------------------------------------------
# CLI-2: --dry-run --no-components omits component:/audience: labels.
# Even if a roadmap.config.yaml existed, --no-components must suppress them.
# We write a minimal config in $TMP to confirm the flag truly suppresses
# component labels when a config file is present.
# ---------------------------------------------------------------------------
FAKE_CONFIG="$TMP/roadmap.config.yaml"
printf 'component_values:\n  - foo\n  - bar\naudience_values:\n  - internal\n' > "$FAKE_CONFIG"

stdout_2="$TMP/cli2.out"
stderr_2="$TMP/cli2.err"
bash "$INSTALLER" --dry-run --no-components --config "$FAKE_CONFIG" >"$stdout_2" 2>"$stderr_2"; rc2=$?

if [ "$rc2" -ne 0 ]; then
  fail_case "CLI-2" "exit $rc2 (expected 0); stderr: $(cat "$stderr_2")"
elif grep -q $'^component:' "$stdout_2"; then
  fail_case "CLI-2" "component: label found despite --no-components"
elif grep -q $'^audience:' "$stdout_2"; then
  fail_case "CLI-2" "audience: label found despite --no-components"
else
  pass "CLI-2: --no-components suppresses component:/audience: labels"
fi

# ---------------------------------------------------------------------------
# CLI-3: --dry-run vocabulary contains the full state-marker set.
# The five state markers (blocked, agent-ready, agent-prep:in-progress,
# provisionally-resolved, provisionally-stale) must appear in dry-run output.
# ---------------------------------------------------------------------------
stdout_3="$TMP/cli3.out"
bash "$INSTALLER" --dry-run >"$stdout_3" 2>/dev/null; rc3=$?

missing_markers=""
for marker in "blocked" "agent-ready" "agent-prep:in-progress" "provisionally-resolved" "provisionally-stale"; do
  grep -q "^${marker}"$'\t' "$stdout_3" || missing_markers="$missing_markers $marker"
done

if [ "$rc3" -ne 0 ]; then
  fail_case "CLI-3" "--dry-run exited $rc3 (expected 0)"
elif [ -n "$missing_markers" ]; then
  fail_case "CLI-3" "missing state markers:$missing_markers"
else
  pass "CLI-3: --dry-run exits 0; all state markers present"
fi

# ---------------------------------------------------------------------------
# CLI-4: tracker guard exits 1 with a backend=github diagnostic when gh is absent.
# Build a PATH that has every real tool the script needs EXCEPT gh, so
# `command -v gh` genuinely fails on any host. `env -i PATH=/usr/bin:/bin`
# does NOT work — CI images ship gh in /usr/bin, so the guard would not fire
# and the test would run live `gh` or assert the wrong message (Codex P1).
# Symlink every command on the current PATH except gh into a temp bin dir.
NOGH_BIN="$TMP/nogh-bin"; mkdir -p "$NOGH_BIN"
IFS=':' read -ra _pdirs <<< "${PATH:-/usr/bin:/bin}"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue                 # skip a non-matching glob
    _b=$(basename "$_f")
    [ "$_b" = gh ] && continue               # the one tool we want absent
    [ -e "$NOGH_BIN/$_b" ] || ln -s "$_f" "$NOGH_BIN/$_b" 2>/dev/null || true
  done
done
stdout_4="$TMP/cli4.out"
stderr_4="$TMP/cli4.err"
# --config pins config behaviour to the fixture so the guard, not a config
# read, is what the live-mode path reaches first.
PATH="$NOGH_BIN" bash "$INSTALLER" --config "$SHARED_CONFIG" >"$stdout_4" 2>"$stderr_4"; rc4=$?

if [ "$rc4" -ne 1 ]; then
  fail_case "CLI-4" "exit $rc4 (expected 1 for gh-absent); stderr: $(cat "$stderr_4")"
elif ! grep -q "gh CLI" "$stderr_4" || ! grep -q "backend=github" "$stderr_4"; then
  fail_case "CLI-4" "expected gh/backend diagnostic in stderr; got: $(cat "$stderr_4")"
else
  pass "CLI-4: tracker guard exits 1 with backend=github gh diagnostic"
fi

# ---------------------------------------------------------------------------
# CLI-5: Unknown flag → exit 2 with stderr, no stdout.
# ---------------------------------------------------------------------------
stdout_5="$TMP/cli5.out"
stderr_5="$TMP/cli5.err"
bash "$INSTALLER" --bogus >"$stdout_5" 2>"$stderr_5"; rc5=$?

if [ "$rc5" -ne 2 ]; then
  fail_case "CLI-5" "exit $rc5 (expected 2 for unknown flag); stderr: $(cat "$stderr_5")"
elif [ -s "$stdout_5" ]; then
  fail_case "CLI-5" "expected empty stdout on bad-arg; got: $(cat "$stdout_5")"
elif ! grep -q "Unknown arg" "$stderr_5"; then
  fail_case "CLI-5" "expected 'Unknown arg' in stderr; got: $(cat "$stderr_5")"
else
  pass "CLI-5: unknown flag exits 2 with error to stderr, empty stdout"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
