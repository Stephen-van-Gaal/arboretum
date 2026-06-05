#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-design-package.sh — Prose-regression checks for the
# design-package skill and the /design invocation seam.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "PASS: $1"; }

DESIGN="skills/design/SKILL.md"
PACKAGE="skills/design-package/SKILL.md"

[ -f "$DESIGN" ] || fail "design skill missing"
[ -f "$PACKAGE" ] || fail "design-package skill missing"

grep -q "^name: design-package$" "$PACKAGE" \
  || fail "design-package frontmatter missing name"
grep -q "^owner: workflow-unification$" "$PACKAGE" \
  || fail "design-package frontmatter missing owner"
grep -q "Build the human review packet for a design session" "$PACKAGE" \
  || fail "design-package description missing review-packet role"
grep -q 'argument-hint: "<path/to/session-design.md>"' "$PACKAGE" \
  || fail "design-package argument hint missing session path"

for phrase in \
  "second Slipstream skill" \
  "invoked by \`design\`" \
  "planning has" \
  "\`plan:\` field is final" \
  "not a standalone workflow stage" \
  "validate-design-spec.sh" \
  "explore-doc.sh" \
  "read-doc-sections.sh" \
  "cataloged shape keys" \
  "discovered heading keys" \
  "fail closed" \
  "unknown"; do
  grep -q "$phrase" "$PACKAGE" \
    || fail "design-package missing phrase: $phrase"
done
ok "design-package states boundary and recognition procedure"

plan_line=$(grep -n "^### 4\. Plan fold-in" "$DESIGN" | cut -d: -f1)
package_line=$(grep -n "^### 5\. Design package" "$DESIGN" | cut -d: -f1)
[ -n "$plan_line" ] || fail "/design missing Step 4 Plan fold-in"
[ -n "$package_line" ] || fail "/design missing Step 5 Design package"
[ "$plan_line" -lt "$package_line" ] \
  || fail "/design must fold in the plan before invoking design-package"
grep -q "After the AI-facing session document and plan exist" "$DESIGN" \
  || fail "/design missing post-plan design-package invocation rule"
grep -q "validate buildability after the \`plan:\` field is final" "$DESIGN" \
  || fail "/design missing post-plan buildability validation rule"
ok "/design runs design-package only after plan fold-in"

for class in strict-design-session partial-design-session custom-s2-design-session plan unknown; do
  grep -q "$class" "$PACKAGE" \
    || fail "design-package missing classification: $class"
done
ok "design-package lists all classifications"

for heading in \
  "Why this session exists" \
  "What will change" \
  "Durable Document Change Set" \
  "Human decisions or review points" \
  "What the AI will do" \
  "Tests and confidence" \
  "Stop conditions"; do
  grep -q "$heading" "$PACKAGE" \
    || fail "design-package missing overview heading: $heading"
done
ok "design-package contains overview standard"

grep -q "| File | Operation | High-Level Change | Why It Matters | Phase |" "$PACKAGE" \
  || fail "design-package missing Durable Document Change Set columns"
grep -q "intent authority" "$PACKAGE" \
  || fail "design-package missing intent authority boundary"
grep -q "seam authority" "$PACKAGE" \
  || fail "design-package missing seam authority boundary"
grep -q "generated/evidence" "$PACKAGE" \
  || fail "design-package missing generated/evidence boundary"
grep -q "durable-doc diff" "$PACKAGE" \
  || fail "design-package missing durable-doc diff review"
ok "design-package contains durable-doc review boundary"

grep -q "design-package" "$DESIGN" \
  || fail "/design does not invoke design-package"
grep -q "Durable Document Change Set" "$DESIGN" \
  || fail "/design missing Durable Document Change Set review"
grep -q "durable-doc diff" "$DESIGN" \
  || fail "/design missing durable-doc diff review"
grep -q "commit and push" "$DESIGN" \
  || fail "/design missing approved durable-doc commit/push gate"
ok "/design invokes design-package and preserves review gate"

echo "ALL PASS: design-package skill invariants"
