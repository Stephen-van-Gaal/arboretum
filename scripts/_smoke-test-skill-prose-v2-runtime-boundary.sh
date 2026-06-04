#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-skill-prose-v2-runtime-boundary.sh - Regression test for stale
# consumer copies of the plugin-only unified skill prose smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CONSUMER="$tmp/consumer"
PLUGIN_BROKEN="$tmp/plugin-broken"

mkdir -p "$CONSUMER/scripts" "$PLUGIN_BROKEN/scripts" "$PLUGIN_BROKEN/.codex-plugin"
cp scripts/_smoke-test-skill-prose-v2.sh "$CONSUMER/scripts/_smoke-test-skill-prose-v2.sh"
cp scripts/_smoke-test-skill-prose-v2.sh "$PLUGIN_BROKEN/scripts/_smoke-test-skill-prose-v2.sh"
printf '{"name":"arboretum"}\n' > "$PLUGIN_BROKEN/.codex-plugin/plugin.json"

if [ -d "$CONSUMER/skills" ]; then
  fail "fixture unexpectedly has top-level skills/"
fi

consumer_out="$tmp/consumer-out.txt"
consumer_err="$tmp/consumer-err.txt"
if bash "$CONSUMER/scripts/_smoke-test-skill-prose-v2.sh" >"$consumer_out" 2>"$consumer_err"; then
  grep -q "SKIP: skill-prose unified invariants require Arboretum plugin skill files" "$consumer_out" \
    || fail "consumer-shaped invocation exited cleanly without the expected skip message" "$(cat "$consumer_out" "$consumer_err")"
  ok "consumer-shaped invocation skips without top-level skills/"
else
  rc=$?
  fail "consumer-shaped invocation failed with exit $rc" "$(cat "$consumer_out" "$consumer_err")"
fi

plugin_out="$tmp/plugin-out.txt"
plugin_err="$tmp/plugin-err.txt"
if bash "$PLUGIN_BROKEN/scripts/_smoke-test-skill-prose-v2.sh" >"$plugin_out" 2>"$plugin_err"; then
  fail "plugin-marked invocation unexpectedly skipped missing skill files" "$(cat "$plugin_out" "$plugin_err")"
else
  grep -q "FAIL: skill-prose unified invariants require Arboretum plugin skill files" "$plugin_err" \
    || fail "plugin-marked invocation failed without the expected missing-skill diagnostic" "$(cat "$plugin_out" "$plugin_err")"
  ok "plugin-marked invocation fails when skill files are missing"
fi

echo "ALL PASS: skill-prose unified runtime boundary"
