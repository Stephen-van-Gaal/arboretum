#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-start-bugfix.sh — Prose and artifact checks for the experimental
# patch-lane bug triage front half.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

START_BUGFIX="skills/start-bugfix/SKILL.md"
START="skills/start/SKILL.md"
BUILD_WORKFLOW="workflows/build.md"
COMMON="ARBORETUM.md"
AGENTS_TEMPLATE="docs/templates/AGENTS.md"
CLAUDE_TEMPLATE="docs/templates/CLAUDE.md"
PATCH_TEMPLATE="docs/templates/patch-brief.md"
PLAN="docs/plans/2026-06-04-patch-lane-bug-triage-front-half.md"
DESIGN="docs/superpowers/specs/2026-06-04-patch-lane-bug-triage-front-half-design.md"

for file in "$PATCH_TEMPLATE" "$PLAN" "$DESIGN"; do
  [ -f "$file" ] || fail "required patch-lane artifact missing: $file"
done
ok "patch-lane design artifacts present"

TMP="${TMPDIR:-/tmp}/start-bugfix-smoke.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/517.md"
cat >"$FIXTURE" <<'MD'
---
date: 2026-06-04
related-issue: 517
triage: agent-target
implementation-mode: direct
plan: null
lane: patch-lane
test-tiers:
  unit: yes
  contract: n/a — no shared definitions touched
  integration: n/a — no cross-spec workflow touched
---

# Patch Brief — #517

## Authority Bundle

| Field | Value |
|---|---|
| Primary authority | docs/specs/workflow-unification.spec.md |
| Read first | Triage fork — verified agent-ready vs. everything-else |
| Required seams | docs/contracts/s2-design-to-build.contract.md |
| In-flight authority | docs/superpowers/specs/2026-06-04-patch-lane-bug-triage-front-half-design.md |
| Warnings | None for fixture |

## Observed Failure

Fixture failure.

## Proposed Correction

Fixture correction.

## Touched Surface

Fixture surface.

## Verification

Fixture verification.

## Escape Hatches

Fixture escape hatch.
MD

bash scripts/validate-design-spec.sh "$FIXTURE" \
  || fail "patch brief fixture should satisfy S2"
grep -q '^lane: patch-lane$' "$FIXTURE" \
  || fail "patch brief fixture missing lane metadata"
for heading in \
  "Authority Bundle" \
  "Observed Failure" \
  "Proposed Correction" \
  "Touched Surface" \
  "Verification" \
  "Escape Hatches"; do
  grep -q "^## $heading$" "$FIXTURE" \
    || fail "patch brief fixture missing heading: $heading"
done
ok "patch brief fixture validates through S2"

[ -f "$START_BUGFIX" ] || fail "missing start-bugfix skill: $START_BUGFIX"

grep -q "roadmap_tracker_issue_show" "$START_BUGFIX" \
  || fail "start-bugfix must fetch supplied issues through roadmap helper"
grep -q "search recent open tracker issues" "$START_BUGFIX" \
  || fail "start-bugfix must search existing tracker issues for raw reports"
grep -q "Do not start investigation until an issue number exists" "$START_BUGFIX" \
  || fail "start-bugfix must require tracker intake before investigation"
ok "tracker intake is required"

grep -q "scripts/read-patch-lane-config.sh" "$START_BUGFIX" \
  || fail "start-bugfix must read patch-lane budget from config helper"
grep -q "Budget expiry is evidence that the report is not patchable" "$START_BUGFIX" \
  || fail "start-bugfix must treat budget expiry as not-patchable evidence"
ok "budget config is used"

for phrase in \
  "Primary authority" \
  "Read first" \
  "Required seams" \
  "In-flight authority" \
  "Warnings"; do
  grep -q "$phrase" "$START_BUGFIX" \
    || fail "authority bundle missing field phrase: $phrase"
done
grep -q "scripts/context-resolve.sh" "$START_BUGFIX" \
  || fail "start-bugfix must use context resolver when present"
grep -q "same bundle manually" "$START_BUGFIX" \
  || fail "start-bugfix must require manual resolver-shape fallback"
ok "authority discovery follows resolver shape"

for phrase in \
  "Existing authority already defines the expected behaviour" \
  "failure is reproducible or directly observable" \
  "restores existing authority" \
  "one owner/spec" \
  "exactly one sensible correction" \
  "Verification is cheap and specific" \
  "No destructive operation" \
  "No escape hatch has fired"; do
  grep -q "$phrase" "$START_BUGFIX" \
    || fail "patchability gate missing phrase: $phrase"
done
ok "patchability gate is complete"

grep -q ".arboretum/patch-briefs/<issue>.md" "$START_BUGFIX" \
  || fail "patchable outcome must write patch brief path"
grep -q "docs/templates/patch-brief.md" "$START_BUGFIX" \
  || fail "patchable outcome must use patch brief template"
grep -q "validate-design-spec.sh" "$START_BUGFIX" \
  || fail "patchable outcome must validate patch brief"
grep -q "/build .arboretum/patch-briefs/<issue>.md" "$START_BUGFIX" \
  || fail "patchable outcome must hand off to /build with patch brief"
grep -q "ready-for-review PR" "$START_BUGFIX" \
  || fail "patchable outcome must target ready-for-review PR"
grep -q "configured or observable AI reviewer feedback" "$START_BUGFIX" \
  || fail "patchable outcome must collect configured/observable AI reviewer feedback"
grep -q "does not merge" "$START_BUGFIX" \
  || fail "patchable outcome must preserve human merge"
ok "patchable outcome handoff is pinned"

for phrase in \
  "reproduction or observation result" \
  "observed behaviour" \
  "authority bundle or authority gap" \
  "suspected area" \
  "why this is not patchable" \
  "recommended next path"; do
  grep -q "$phrase" "$START_BUGFIX" \
    || fail "not-patchable issue update missing phrase: $phrase"
done
grep -q "stops after updating or creating the issue" "$START_BUGFIX" \
  || fail "not-patchable outcome must stop"
ok "not-patchable outcome is pinned"

grep -q "/start-bugfix" "$START" \
  || fail "/start must mention the experimental start-bugfix handoff"
grep -q "/start-bugfix" "$BUILD_WORKFLOW" \
  || fail "build workflow must mention start-bugfix front half"
ok "workflow entry surfaces mention start-bugfix"

for file in "$COMMON" "$AGENTS_TEMPLATE" "$CLAUDE_TEMPLATE"; do
  grep -q "verified patch-lane briefs produced by \`/start-bugfix\`" "$file" \
    || fail "common contract missing patch-lane exception in $file"
done
ok "common review-before-build exception is mirrored"

echo "start-bugfix smoke: ALL PASS"
