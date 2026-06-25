#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/read-doc-sections.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && {
    echo "--- detail ---" >&2
    echo "$2" >&2
  }
  fail=1
}

out=$(bash "$PROBE" "$ROOT/docs/templates/spec.md" behaviour purpose 2>"$FIX/err"); rc=$?
behaviour_line=$(printf '%s\n' "$out" | awk '/^## Behaviour$/ { print NR; exit }')
purpose_line=$(printf '%s\n' "$out" | awk '/^## Purpose$/ { print NR; exit }')
if [ "$rc" = 0 ] \
  && [ -n "$behaviour_line" ] \
  && [ -n "$purpose_line" ] \
  && [ "$behaviour_line" -lt "$purpose_line" ]; then
  pass "multi-key retrieval follows requested order"
else
  fail_case "requested-order retrieval" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out=$(bash "$PROBE" "$ROOT/docs/templates/spec.md" non-goals 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Boundaries (non-goals)$'; then
  pass "alias keys resolve to canonical section headings"
else
  fail_case "alias resolution" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

out_file="$FIX/missing.out"
err_file="$FIX/missing.err"
if bash "$PROBE" "$ROOT/docs/templates/spec.md" purpose missing-key >"$out_file" 2>"$err_file"; then
  fail_case "missing key should fail"
else
  if [ ! -s "$out_file" ] && grep -q "missing-key" "$err_file"; then
    pass "missing key fails without partial stdout"
  else
    fail_case "missing key failure contract" "out=$(cat "$out_file") err=$(cat "$err_file")"
  fi
fi

out=$(bash "$PROBE" "$ROOT/docs/templates/spec.md" purpose 2>"$FIX/err"); rc=$?
if [ "$rc" = 0 ] \
  && printf '%s\n' "$out" | grep -q '^## Purpose$' \
  && ! printf '%s\n' "$out" | grep -q '^## Boundaries (non-goals)$'; then
  pass "single-section reader boundaries remain intact"
else
  fail_case "boundary preservation" "rc=$rc out=$out err=$(cat "$FIX/err")"
fi

[ "$fail" = 0 ] && echo "read-doc-sections contract: ALL PASS" || exit 1
