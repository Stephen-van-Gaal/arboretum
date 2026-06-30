#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-haiku-dispatch-model.sh — Assert the two skills that dispatch an
# internal Haiku sub-task set an explicit, concrete Haiku model parameter at the
# dispatch site (model-routing proof-of-mechanism, #733 / MR2).
#
# Both sites previously declared the Haiku intent in prose only ("Dispatch a
# subagent (Haiku)") without ever passing a model — so the sub-task could run on
# the session's frontier default. This test fails if the explicit model
# directive is removed from either site (test-the-test: it must catch regression
# back to prose-only intent).
#
# Usage: bash scripts/_smoke-test-haiku-dispatch-model.sh
# Exit 0 if both directives present, 1 otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROADMAP="$ROOT/skills/roadmap/SKILL.md"
EXTRACT="$ROOT/skills/extract-component/SKILL.md"

# A Haiku model directive is satisfied EITHER by the concrete id (the original
# #733/MR2 proof-of-mechanism) OR by resolving the `cheap` family through the
# central map (#924/MR4 — the concrete id now lives single-sourced in
# scripts/lib/model-families.sh, so the dispatch sites resolve `cheap`).
MODEL_ID='claude-haiku-4-5'
FAMILY_DIRECTIVE='resolve_model_family[[:space:]]+cheap'

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

# A "model directive" is a single line that names the model parameter and either
# the concrete id or the `cheap` family resolution — i.e. it tells the dispatcher
# what to pass, not just that the sub-task is "Haiku-ish".
assert_model_directive() {
  local file="$1" label="$2"
  [ -f "$file" ] || { fail "$label: file not found ($file)"; return; }
  if grep -qiE "model.*(${MODEL_ID}|${FAMILY_DIRECTIVE})|(${MODEL_ID}|${FAMILY_DIRECTIVE}).*model" "$file"; then
    pass "$label sets an explicit \`model\` directive (concrete id or cheap family)"
  else
    fail "$label has no explicit model directive (concrete id or resolve_model_family cheap) — prose-only intent is a regression"
  fi
}

assert_model_directive "$ROADMAP" "roadmap §5 free-form NL subagent dispatch"
assert_model_directive "$EXTRACT" "extract-component Tier-3 agentic confirm dispatch"

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $fail_count dispatch site(s) missing an explicit Haiku model directive" >&2
  exit 1
fi

echo "PASS: both Haiku sub-dispatch sites set an explicit model parameter"
