#!/usr/bin/env bash
# owner: skill-and-agent-authoring
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

# Concrete Haiku-class model id — matches the repo literal in
# docs/superpowers/2026-06-06-token-cost-optimization-explore.md. The
# family→id abstraction (cheap/capable/frontier, MR4) is out of scope for #733.
MODEL_ID='claude-haiku-4-5'

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

# A "model directive" is a single line that both names the model parameter and
# the concrete id — i.e. it tells the dispatcher what to pass, not just that the
# sub-task is "Haiku-ish". A bare mention of the id elsewhere does not satisfy.
assert_model_directive() {
  local file="$1" label="$2"
  [ -f "$file" ] || { fail "$label: file not found ($file)"; return; }
  if grep -qiE "model.*${MODEL_ID}|${MODEL_ID}.*model" "$file"; then
    pass "$label sets an explicit \`model\` parameter to ${MODEL_ID}"
  else
    fail "$label has no explicit model directive naming ${MODEL_ID} (prose-only intent is a regression)"
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
