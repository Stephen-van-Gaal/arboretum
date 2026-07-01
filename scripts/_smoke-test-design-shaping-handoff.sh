#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
# Prose smoke: /design shaping-exit hands off to /finish (not terminal) after
# human approval. Guards design #935 §1 / D3.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/design/SKILL.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }

# The shaping exit must now name /finish as the handoff target.
grep -qiE 'kind: ?shaping' "$SKILL" || note "/design lost the kind:shaping exit branch"
# Behavioural: the shaping exit hands off to /finish (not a bare /finish mention
# elsewhere in the file — the replacement prose uses "hands off to /finish").
grep -qiE 'hands off to .?/finish' "$SKILL" \
  || note "/design shaping-exit does not hand off to /finish"
# Regression: the old terminal framing must be gone.
grep -qiE 'terminal at human review|exit is terminal' "$SKILL" \
  && note "/design still describes the shaping exit as terminal"
# Human-review gate is preserved (handoff is AFTER approval).
grep -qiE 'human review|approves? the design package' "$SKILL" \
  || note "/design dropped the human-review gate"

[ "$fail" -eq 0 ] && echo "PASS: design-shaping-handoff" || exit 1
