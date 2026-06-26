#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# Smoke test for docs/dev-contracts/release/release-intent.cli-contract.md.
# Exercises release-intent parsing from PR body files and GitHub event JSON.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/dev-tools/release/read-release-intent.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail=0

expect_fail() {
  local name="$1"
  shift
  if "$@" >"$TMPDIR/out" 2>"$TMPDIR/err"; then
    echo "FAIL: $name should fail" >&2
    fail=1
    return
  fi
}

valid="$TMPDIR/valid.md"
cat >"$valid" <<'BODY'
## Summary
- changes shippable content

## Release Intent
release-impact: patch
release-state: pending
BODY

out="$(bash "$SCRIPT" --body-file "$valid" 2>"$TMPDIR/err")"
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s\n' "$out" | grep -Fxq 'release-impact=patch' \
  && printf '%s\n' "$out" | grep -Fxq 'release-state=pending' \
  && printf '%s\n' "$out" | grep -Fxq 'source=body'; then
  echo "PASS: valid pending patch intent"
else
  echo "FAIL: valid pending patch intent rc=$rc output=$out err=$(cat "$TMPDIR/err")" >&2
  fail=1
fi

none="$TMPDIR/none.md"
cat >"$none" <<'BODY'
## Release Intent
release-impact: none
release-state: not-needed
BODY
out="$(bash "$SCRIPT" --body-file "$none" 2>"$TMPDIR/err")"
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s\n' "$out" | grep -Fxq 'release-impact=none' \
  && printf '%s\n' "$out" | grep -Fxq 'release-state=not-needed'; then
  echo "PASS: explicit none intent"
else
  echo "FAIL: explicit none intent rc=$rc output=$out err=$(cat "$TMPDIR/err")" >&2
  fail=1
fi

missing="$TMPDIR/missing.md"
printf '## Summary\nno section\n' >"$missing"
expect_fail "missing release intent section" bash "$SCRIPT" --body-file "$missing"
grep -q 'release intent section missing' "$TMPDIR/err" \
  && echo "PASS: missing section rejected" \
  || { echo "FAIL: missing section diagnostic not found" >&2; fail=1; }

invalid="$TMPDIR/invalid.md"
cat >"$invalid" <<'BODY'
## Release Intent
release-impact: banana
release-state: pending
BODY
expect_fail "invalid impact" bash "$SCRIPT" --body-file "$invalid"
grep -q 'invalid release-impact' "$TMPDIR/err" \
  && echo "PASS: invalid impact rejected" \
  || { echo "FAIL: invalid impact diagnostic not found" >&2; fail=1; }

bad_state="$TMPDIR/bad-state.md"
cat >"$bad_state" <<'BODY'
## Release Intent
release-impact: patch
release-state: banana
BODY
expect_fail "invalid state" bash "$SCRIPT" --body-file "$bad_state"
grep -q 'invalid release-state' "$TMPDIR/err" \
  && echo "PASS: invalid state rejected" \
  || { echo "FAIL: invalid state diagnostic not found" >&2; fail=1; }

duplicate="$TMPDIR/duplicate.md"
cat >"$duplicate" <<'BODY'
## Release Intent
release-impact: patch
release-impact: minor
release-state: pending
BODY
expect_fail "duplicate key" bash "$SCRIPT" --body-file "$duplicate"
grep -q 'duplicate release-impact' "$TMPDIR/err" \
  && echo "PASS: duplicate key rejected" \
  || { echo "FAIL: duplicate key diagnostic not found" >&2; fail=1; }

event="$TMPDIR/event.json"
python3 - "$event" <<'PY'
import json
import sys

body = """## Summary

## Release Intent
release-impact: minor
release-state: pending
"""
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"pull_request": {"body": body}}, fh)
PY
out="$(bash "$SCRIPT" --github-event "$event" 2>"$TMPDIR/err")"
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s\n' "$out" | grep -Fxq 'release-impact=minor' \
  && printf '%s\n' "$out" | grep -Fxq 'release-state=pending' \
  && printf '%s\n' "$out" | grep -Fxq 'source=github-event'; then
  echo "PASS: GitHub event body parsed"
else
  echo "FAIL: GitHub event body parse rc=$rc output=$out err=$(cat "$TMPDIR/err")" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
