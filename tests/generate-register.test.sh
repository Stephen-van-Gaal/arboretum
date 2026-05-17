#!/usr/bin/env bash
# generate-register.test.sh — Regression tests for scripts/generate-register.sh
#
# Run:
#   bash tests/generate-register.test.sh
#
# These tests invoke the target script under /bin/bash. On macOS that is
# bash 3.2, which — unlike bash 4.4+ — raises "unbound variable" under
# `set -u` when "${arr[@]}" expands an empty *declared* array. That is the
# exact environment issue #8 was reported from. On systems where /bin/bash
# is bash 4.4+, the tests still pass; they just cannot reproduce the failure.
# Override the interpreter with TARGET_BASH=/path/to/bash if needed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/generate-register.sh"
TARGET_BASH="${TARGET_BASH:-/bin/bash}"

pass=0
fail=0

pass_test() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# Write a throwaway project dir containing a single spec file.
#   $1 = project dir   $2 = spec filename   $3 = full spec body
make_project() {
  local dir="$1" spec="$2" body="$3"
  mkdir -p "$dir/docs/specs"
  printf '%s\n' "$body" > "$dir/docs/specs/$spec"
}

# ── Test 1: a spec with no `owns:` field must not crash ──────────────
# Regression for issue #8: extract_owns_list leaves `patterns` an empty
# declared array, so "${patterns[@]}" trips `set -u` on bash < 4.4. The
# error fires inside a process substitution, so the script still exits 0 —
# the stderr message is the only reliable signal.
test_empty_owns_no_crash() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  make_project "$tmp" "no-owns.spec.md" "---
name: no-owns
status: active
owner: nobody
---

# No Owns

This spec deliberately declares no owns list."

  local err rc
  err="$("$TARGET_BASH" "$SCRIPT" "$tmp" 2>&1 1>/dev/null)"
  rc=$?

  if printf '%s' "$err" | grep -q 'unbound variable'; then
    fail_test "spec with no owns: triggers 'unbound variable' -> $err"
  elif [ "$rc" -ne 0 ]; then
    fail_test "spec with no owns: exited non-zero ($rc) -> $err"
  elif [ ! -f "$tmp/docs/REGISTER.md" ]; then
    fail_test "spec with no owns: REGISTER.md was not generated"
  else
    pass_test "spec with no owns: generates register without crashing"
  fi
}

# ── Test 2: a spec WITH owns: still resolves correctly ───────────────
# Guards the fix against over-guarding — the populated path must keep working.
test_with_owns_still_resolves() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/src"
  : > "$tmp/src/thing.txt"
  make_project "$tmp" "has-owns.spec.md" "---
name: has-owns
status: active
owner: somebody
owns:
  - src/thing.txt
---

# Has Owns"

  local err
  err="$("$TARGET_BASH" "$SCRIPT" "$tmp" 2>&1 1>/dev/null)"

  if printf '%s' "$err" | grep -q 'unbound variable'; then
    fail_test "spec with owns: triggers 'unbound variable' -> $err"
  elif ! grep -q 'src/thing.txt' "$tmp/docs/REGISTER.md" 2>/dev/null; then
    fail_test "spec with owns: 'src/thing.txt' missing from REGISTER.md"
  else
    pass_test "spec with owns: resolves owned files into the register"
  fi
}

# ── Run ──────────────────────────────────────────────────────────────

echo "generate-register.sh regression tests"
echo "target interpreter: $("$TARGET_BASH" --version | head -1)"
echo

test_empty_owns_no_crash
test_with_owns_still_resolves

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
