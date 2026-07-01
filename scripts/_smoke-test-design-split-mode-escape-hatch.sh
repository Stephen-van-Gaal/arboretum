#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-design-split-mode-escape-hatch.sh — Asserts the produce-driver
# escape-hatch path (#944): create a minimal draft spec, then attach an
# escape-hatch block, matching skills/design/SKILL.md's Produce dispatch step.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE_HATCH="$SCRIPT_DIR/write-escape-hatch.sh"
[ -f "$WRITE_HATCH" ] || { echo "FAIL: $WRITE_HATCH not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
DRAFT="$FIX/2026-07-01-scratch-design.md"

# Minimal draft spec, as produce would create before attaching an escape-hatch
# when no spec file exists yet.
cat > "$DRAFT" <<'EOF'
---
date: 2026-07-01
topic: scratch
status: design
related-issue: 999
triage: everything-else
document-shape: design-spec
implementation-mode: direct
plan: null
test-tiers:
  unit: yes
  contract: n/a — spike
  integration: n/a — spike
---

# Scratch Design

## Context

Draft created by the produce driver before it could finish authoring.
EOF

bash "$WRITE_HATCH" "$DRAFT" "ambiguous-requirement" "resident-elicit" > /dev/null
ec=$?

if [ "$ec" -eq 0 ] && grep -q "^escape-hatch:$" "$DRAFT" \
   && grep -q "trigger: ambiguous-requirement" "$DRAFT" \
   && grep -q "redirect-target: resident-elicit" "$DRAFT"; then
  pass "escape-hatch attaches cleanly to a freshly-created minimal draft spec"
else
  fail_case "escape-hatch attach on a minimal draft failed (exit=$ec)" "$(cat "$DRAFT")"
fi

# Idempotency: a second call replaces, not duplicates.
bash "$WRITE_HATCH" "$DRAFT" "still-ambiguous" "resident-elicit" > /dev/null
count=$(grep -c "^escape-hatch:$" "$DRAFT")
if [ "$count" = "1" ] && grep -q "trigger: still-ambiguous" "$DRAFT"; then
  pass "a second escape-hatch call replaces in place, not duplicates"
else
  fail_case "expected exactly one escape-hatch block after re-attach, got $count" "$(cat "$DRAFT")"
fi

if [ "$fail" -eq 0 ]; then
  echo "All design-split-mode escape-hatch assertions passed."
  exit 0
else
  exit 1
fi
