#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-model-families.sh — model-families.sh map contract:
# totality over the three families, fail-loud on unknown, and single-sourcing of
# the concrete model ids (no other surface restates them).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/model-families.sh"

fail=0; fail(){ echo "FAIL: $1" >&2; fail=$((fail+1)); }; pass(){ echo "PASS: $1"; }

# Totality + non-empty
for fam in cheap capable frontier; do
  if id="$(resolve_model_family "$fam")" && [ -n "$id" ]; then
    pass "$fam -> $id"
  else
    fail "$fam did not resolve to a non-empty id"
  fi
done

# Fail loud on unknown
if resolve_model_family bogus 2>/dev/null; then
  fail "unknown family did not error"
else
  pass "unknown family fails loud"
fi

# Single source: each concrete id appears only in model-families.sh
for id in claude-haiku-4-5 claude-sonnet-5 claude-opus-4-8; do
  hits="$(grep -rl --include='*.sh' --include='*.md' -- "$id" "$ROOT/scripts" "$ROOT/skills" 2>/dev/null \
    | grep -vE '_smoke-test-|/contracts/|model-families\.sh$' || true)"
  if [ -z "$hits" ]; then
    pass "$id single-sourced"
  else
    fail "$id also appears in: $(echo "$hits" | tr '\n' ' ')"
  fi
done

[ "$fail" -eq 0 ] || { echo "" >&2; echo "FAIL: $fail assertion(s)" >&2; exit 1; }
echo "PASS: model-families map"
