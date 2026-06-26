#!/usr/bin/env bash
# owner: arboretum-as-plugin
# scope: plugin-only
# ci-parallel: safe
#
# _smoke-test-seed-settings.sh — exercises seed-settings.sh across the three
# target states (absent, hooks-only, pre-populated allow) plus the jq-absent
# path. Guards the DD5 merge contract from issue #245.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$ROOT/seed-settings.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SEED" ] || fail "seed-settings.sh not found at $SEED"
command -v jq >/dev/null 2>&1 || fail "jq required to run this smoke test"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build an isolated bin with symlinks to required utilities but no jq.
# This guarantees T4 works regardless of where the host jq is installed.
ISOLATED_BIN="$WORK/isolated-bin"
mkdir -p "$ISOLATED_BIN"
for _cmd in bash cp printf; do
  _loc=$(command -v "$_cmd" 2>/dev/null) && ln -sf "$_loc" "$ISOLATED_BIN/$_cmd" || true
done

# Minimal template fixture — independent of the real template's content.
TEMPLATE="$WORK/template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(bash scripts/health-check.sh *)",
      "Bash(git status *)"
    ]
  },
  "hooks": { "SessionStart": [] }
}
JSON

# Test 1: target absent → template copied verbatim.
T1="$WORK/t1.json"
bash "$SEED" "$T1" "$TEMPLATE" >/dev/null
[ -f "$T1" ] || fail "T1: target not created"
jq -e '.permissions.allow | length == 2' "$T1" >/dev/null \
  || fail "T1: allow list not copied"
echo "PASS: T1 absent target → copied"

# Test 2: hooks-only target (no permissions key) → merged, no throw.
T2="$WORK/t2.json"
cat > "$T2" <<'JSON'
{ "hooks": { "SessionStart": [{ "matcher": "startup" }] } }
JSON
bash "$SEED" "$T2" "$TEMPLATE" >/dev/null \
  || fail "T2: merge threw on a hooks-only target"
jq -e '.permissions.allow | length == 2' "$T2" >/dev/null \
  || fail "T2: allow list not added"
jq -e '.hooks.SessionStart[0].matcher == "startup"' "$T2" >/dev/null \
  || fail "T2: existing hooks block not preserved"
echo "PASS: T2 hooks-only target → merged, hooks preserved"

# Test 3: pre-populated allow → union, dedup, existing-first order.
T3="$WORK/t3.json"
cat > "$T3" <<'JSON'
{ "permissions": { "allow": [ "Bash(git status *)", "Bash(custom-tool *)" ] } }
JSON
bash "$SEED" "$T3" "$TEMPLATE" >/dev/null
jq -e '.permissions.allow == [
  "Bash(git status *)",
  "Bash(custom-tool *)",
  "Bash(bash scripts/health-check.sh *)"
]' "$T3" >/dev/null \
  || fail "T3: expected existing entries first, new appended, git status not duplicated"
echo "PASS: T3 pre-populated allow → union with dedup"

# Test 4: jq absent → loud message, non-fatal exit 0, target untouched.
# Uses ISOLATED_BIN (no jq symlink) so the test is environment-independent.
T4="$WORK/t4.json"
cat > "$T4" <<'JSON'
{ "hooks": { "SessionStart": [] } }
JSON
BEFORE="$(cat "$T4")"
T4_ERR="$WORK/t4.err"
PATH="$ISOLATED_BIN" bash "$SEED" "$T4" "$TEMPLATE" >/dev/null 2>"$T4_ERR" \
  || fail "T4: jq-absent path must exit 0 (non-fatal)"
[ "$(cat "$T4")" = "$BEFORE" ] || fail "T4: target modified despite jq absent"
grep -q '\[seed-settings\] jq not found' "$T4_ERR" \
  || fail "T4: jq-absent path must print the '[seed-settings] jq not found' guidance"
echo "PASS: T4 jq absent → non-fatal, target untouched, guidance printed"

echo "ALL PASS: _smoke-test-seed-settings.sh"
