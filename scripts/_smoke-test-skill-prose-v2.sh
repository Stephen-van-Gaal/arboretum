#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-skill-prose-v2.sh — Prose-regression checks for the v2-only
# sections of /start and /design. These are structural invariants —
# accidental edits that break the v2 routing will be caught here.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

START="skills/start/SKILL.md"
DESIGN="skills/design/SKILL.md"
FINISH="skills/finish/SKILL.md"
CLEANUP="skills/cleanup/SKILL.md"
CONSOLIDATE="skills/consolidate/SKILL.md"
HEALTH="skills/health-check/SKILL.md"

missing_skill_files=()
for skill_file in "$START" "$DESIGN" "$FINISH" "$CLEANUP" "$CONSOLIDATE" "$HEALTH"; do
  [ -f "$skill_file" ] || missing_skill_files+=("$skill_file")
done

if [ "${#missing_skill_files[@]}" -gt 0 ]; then
  if [ -f ".codex-plugin/plugin.json" ] || [ -f ".claude-plugin/plugin.json" ]; then
    fail "skill-prose v2 invariants require Arboretum plugin skill files" \
      "$(printf 'missing %s\n' "${missing_skill_files[@]}")"
  fi
  echo "SKIP: skill-prose v2 invariants require Arboretum plugin skill files"
  printf 'SKIP: missing %s\n' "${missing_skill_files[@]}"
  exit 0
fi

# /start invariants

# Case 1: Step 0 (flag read) exists in /start
grep -q "^### 0\. Read the pipeline\.workflow flag" "$START" \
  || fail "case 1 — /start Step 0 (flag read) missing"
ok "case 1 — /start Step 0 present"

# Case 2: Step 4-v2 (agent-target triage) exists in /start
grep -q "^### 4-v2\. Agent-target triage" "$START" \
  || fail "case 2 — /start Step 4-v2 missing"
ok "case 2 — /start Step 4-v2 present"

# Case 2a: /start honours agent-ready as a contract only after freshness verification
grep -q "scripts/verify-agent-ready.sh <issue>" "$START" \
  || fail "case 2a — /start does not invoke verify-agent-ready.sh for labelled issues"
grep -q "Do \*\*not\*\* re-screen labelled issues" "$START" \
  || fail "case 2a — /start does not document the labelled-issue pre-screen skip"
ok "case 2a — /start verifies agent-ready freshness before fast-lane use"

# Case 2b: /start refuses stale/invalid agent-ready labels
grep -q "Do \*\*not\*\* implement from it" "$START" \
  || fail "case 2b — /start does not refuse stale agent-ready labels"
grep -q "/roadmap agent-prep <issue>" "$START" \
  || fail "case 2b — /start does not route stale agent-ready labels back through agent-prep"
ok "case 2b — /start refuses stale/invalid agent-ready labels"

# Case 2c: /start verifies and writes from the same issue snapshot
grep -q -- "--issue-file \"\$issue_json\"" "$START" \
  || fail "case 2c — /start does not verify the saved issue snapshot"
grep -q "verified JSON snapshot" "$START" \
  || fail "case 2c — /start does not require brief writes from the verified snapshot"
ok "case 2c — /start reuses the verified issue snapshot for brief creation"

# Case 2d: /start distinguishes helper preflight/input failures from stale labels
grep -q "If it exits \`2\`" "$START" \
  || fail "case 2d — /start does not document verify-agent-ready exit 2"
grep -q "do not route it through \`/roadmap agent-prep\`" "$START" \
  || fail "case 2d — /start still routes helper setup failures through agent-prep"
ok "case 2d — /start handles verify-agent-ready exit 2 separately"

# Case 3: /start v2 everything-else routes to /design (PR2's central edit)
grep -q "Hand off to \`/design\` with the issue number" "$START" \
  || fail "case 3 — /start v2 everything-else does not invoke /design"
ok "case 3 — /start v2 everything-else routes to /design"

# Case 4: /start no longer falls through to v1 Path A/B under v2
if grep -q "For PR1 of WS2, continue with Step 4 (Path A/B determination)" "$START"; then
  fail "case 4 — /start v2 everything-else still has the PR1 fallback prose"
fi
ok "case 4 — /start v2 everything-else fallback removed"

# /design invariants

# Case 5: /design Step 0 (flag read) exists
grep -q "^### Step 0: Read the pipeline\.workflow flag" "$DESIGN" \
  || fail "case 5 — /design Step 0 (flag read) missing"
ok "case 5 — /design Step 0 present"

# Case 6: /design Step 0-v1 exists (the renamed v1-only path-selection step)
grep -q "^### Step 0-v1: Determine path — A or B?" "$DESIGN" \
  || fail "case 6 — /design Step 0-v1 missing (rename of old Step 0)"
ok "case 6 — /design Step 0-v1 present"

# Case 7: /design Section v2 exists
grep -q "^## Section v2: Unified design phase" "$DESIGN" \
  || fail "case 7 — /design Section v2 missing"
ok "case 7 — /design Section v2 present"

# Case 8: /design Section v2 has all 5 sub-sections (v2.1 through v2.5)
SUBS=$(grep -c "^### v2\." "$DESIGN")
[ "$SUBS" = "5" ] || fail "case 8 — /design Section v2 expected 5 sub-sections, found $SUBS"
ok "case 8 — /design Section v2 has 5 sub-sections (v2.1-v2.5)"

# Case 9: /design Section v2 names all 4 Branch 1 modes (D5).
# Extract just Section v2 (delimited by `## Section v2:` and the next `## ` heading)
# so v1 occurrences of mode words don't false-pass the check.
SECTION_V2=$(awk '
  /^## Section v2:/ { flag = 1; next }
  /^## / && flag { flag = 0 }
  flag { print }
' "$DESIGN")
for mode in brainstorm investigate coverage-baseline none; do
  echo "$SECTION_V2" | grep -q "$mode" \
    || fail "case 9 — /design Section v2 missing Branch 1 mode: $mode"
done
ok "case 9 — /design Section v2 names all 4 Branch 1 modes (scoped to v2 block only)"

# Case 10: /design Section v2 invokes superpowers:writing-plans
grep -q "superpowers:writing-plans" "$DESIGN" \
  || fail "case 10 — /design Section v2 does not invoke superpowers:writing-plans"
ok "case 10 — /design Section v2 folds in planning via superpowers:writing-plans"

# Case 10a: /design Section v2 requires customer/operator experience guidance
echo "$SECTION_V2" | grep -Eq "Customer Experience|customer/operator experience" \
  || fail "case 10a — /design Section v2 missing customer/operator experience guidance"
for phrase in "workflow steps" "ship-tail behaviour" "error or warning states" "user decisions or confirmations" "trust boundaries"; do
  echo "$SECTION_V2" | grep -q "$phrase" \
    || fail "case 10a — /design customer/operator guidance missing trigger phrase: $phrase"
done
for phrase in "normal path" "failure or unknown path" "user decision points"; do
  echo "$SECTION_V2" | grep -q "$phrase" \
    || fail "case 10a — /design customer/operator guidance missing coverage phrase: $phrase"
done
ok "case 10a — /design Section v2 covers customer/operator experience guidance"

# Case 11: /design Section v2 exits to /build with design spec path
grep -q "/build docs/superpowers/specs" "$DESIGN" \
  || fail "case 11 — /design Section v2 does not exit to /build with design spec path"
ok "case 11 — /design Section v2 exits to /build correctly"

# PR3: /finish, /consolidate, /health-check invariants

# Case 12: /finish has Step 0 (flag read)
grep -q "^### Step 0: Read the pipeline\.workflow flag" "$FINISH" \
  || fail "case 12 — /finish Step 0 (flag read) missing"
ok "case 12 — /finish Step 0 present"

# Case 13: /finish has Section v2 note
grep -q "^## Section v2: Ship-tail under the unified workflow" "$FINISH" \
  || fail "case 13 — /finish Section v2 missing"
ok "case 13 — /finish Section v2 present"

# Case 13a: /finish Step 1 offers an in-flow commit checkpoint instead of only hard-pausing
grep -Fq "stage named files + commit checkpoint" "$FINISH" \
  || fail "case 13a — /finish Step 1 does not offer the named-file commit checkpoint"
grep -Fq "git add -- <file> [<file>...]" "$FINISH" \
  || fail "case 13a — /finish checkpoint does not preserve explicit named-file staging"
grep -Fq "git commit --only -m \"<message>\" -- <file> [<file>...]" "$FINISH" \
  || fail "case 13a — /finish checkpoint does not restrict commit contents to named files"
ok "case 13a — /finish Step 1 offers an explicit named-file commit checkpoint"

# Case 14: /health-check has Step 0 (flag read)
grep -q "^### Step 0: Read the pipeline\.workflow flag" "$HEALTH" \
  || fail "case 14 — /health-check Step 0 (flag read) missing"
ok "case 14 — /health-check Step 0 present"

# Case 15: /health-check has Section v2 note
grep -q "^## Section v2: Health-check under the unified workflow" "$HEALTH" \
  || fail "case 15 — /health-check Section v2 missing"
ok "case 15 — /health-check Section v2 present"

# Case 16: /consolidate has Step 0 (flag read)
grep -q "^### Step 0: Read the pipeline\.workflow flag" "$CONSOLIDATE" \
  || fail "case 16 — /consolidate Step 0 (flag read) missing"
ok "case 16 — /consolidate Step 0 present"

# Case 17: /consolidate has Section v2
grep -q "^## Section v2: Unified-workflow reconciliation" "$CONSOLIDATE" \
  || fail "case 17 — /consolidate Section v2 missing"
ok "case 17 — /consolidate Section v2 present"

# Case 18: /consolidate Section v2 has all 5 sub-sections (v2.1 through v2.5).
# Scope the count to the Section v2 block only — a future unrelated `### v2.`
# heading elsewhere in the file would otherwise let this case pass/fail
# spuriously. Mirrors the pattern used by cases 9 and 22.
CONS_SECTION_V2_BLOCK=$(awk '
  /^## Section v2:/ { flag = 1; next }
  /^## / && flag { flag = 0 }
  flag { print }
' "$CONSOLIDATE")
CONS_SUBS=$(echo "$CONS_SECTION_V2_BLOCK" | grep -c "^### v2\.")
[ "$CONS_SUBS" = "5" ] || fail "case 18 — /consolidate Section v2 expected 5 sub-sections (scoped to v2 block), found $CONS_SUBS"
ok "case 18 — /consolidate Section v2 has 5 sub-sections (scoped to v2 block)"

# Case 19: /consolidate v2.2 D3 hybrid supersession exists
grep -q "D3 hybrid behaviour-supersession detection" "$CONSOLIDATE" \
  || fail "case 19 — /consolidate v2.2 D3 supersession heading missing"
ok "case 19 — /consolidate v2.2 D3 supersession present"

# Case 20: /consolidate v2.3 D5 refactor handling exists
grep -q "D5 refactor-spec handling" "$CONSOLIDATE" \
  || fail "case 20 — /consolidate v2.3 D5 refactor handling missing"
ok "case 20 — /consolidate v2.3 D5 refactor handling present"

# Case 21: /consolidate Step 5b status-determination prose carries v1-only annotation
grep -q "Determine status (v1 only — skip under v2" "$CONSOLIDATE" \
  || fail "case 21 — /consolidate Step 5b status prose missing v1-only annotation"
ok "case 21 — /consolidate v1-only annotation present on Step 5b status determination"

# Case 22: /consolidate v2.1 collapses new-spec status to always-active
SECTION_V2_CONS=$(awk '
  /^## Section v2:/ { flag = 1; next }
  /^## / && flag { flag = 0 }
  flag { print }
' "$CONSOLIDATE")
echo "$SECTION_V2_CONS" | grep -q "always \`active\`" \
  || fail "case 22 — /consolidate v2.1 does not state status is always \`active\`"
ok "case 22 — /consolidate v2.1 collapses status to always-active"

# === PR4 cutover invariants ===

# Case 23: workflows/build.md exists with the right frontmatter
[ -f "workflows/build.md" ] || fail "case 23 — workflows/build.md missing"
grep -q "^name: build$" workflows/build.md \
  || fail "case 23 — workflows/build.md frontmatter missing 'name: build'"
ok "case 23 — workflows/build.md present"

# Case 24: workflows/build.md declares the unified stage sequence
grep -q "^### 1\. Triage" workflows/build.md \
  || fail "case 24 — workflows/build.md missing triage section"
grep -q "^### 2\. Design" workflows/build.md \
  || fail "case 24 — workflows/build.md missing design section"
grep -q "^### 5\. Security review" workflows/build.md \
  || fail "case 24 — workflows/build.md missing security-review section"
ok "case 24 — workflows/build.md has unified stage sequence"

# Case 25: the 4 legacy workflow docs are absent
for legacy in feature bug-fix refactor documentation; do
  [ ! -f "workflows/$legacy.md" ] || fail "case 25 — legacy workflow doc still present: workflows/$legacy.md"
done
ok "case 25 — 4 legacy workflow docs absent"

# Case 26: pipeline.workflow default is v2
[ "$(bash scripts/read-pipeline-flag.sh)" = "v2" ] \
  || fail "case 26 — pipeline.workflow is not v2"
ok "case 26 — pipeline.workflow default is v2"

# Case 27: two-path-governance.spec.md is no longer a live spec
[ ! -f "docs/specs/two-path-governance.spec.md" ] \
  || fail "case 27 — two-path-governance.spec.md is still in docs/specs/ (should be in _deprecated/)"
[ -f "docs/specs/_deprecated/two-path-governance.spec.md" ] \
  || fail "case 27 — _deprecated/two-path-governance.spec.md missing"
ok "case 27 — two-path-governance deprecated via relocation"

# Case 28: workflow-unification.spec.md exists with status active
[ -f "docs/specs/workflow-unification.spec.md" ] \
  || fail "case 28 — workflow-unification.spec.md missing"
grep -q "^status: active$" docs/specs/workflow-unification.spec.md \
  || fail "case 28 — workflow-unification.spec.md status is not active"
ok "case 28 — workflow-unification.spec.md present and active"

# Case 29: workflow-management.spec.md is gone (merged into workflow-unification)
[ ! -f "docs/specs/workflow-management.spec.md" ] \
  || fail "case 29 — workflow-management.spec.md still present (should be merged into workflow-unification)"
ok "case 29 — workflow-management.spec.md merged into workflow-unification"

# Case 30: no # owner: workflow-management headers remain in live source
if grep -rln "^# owner: workflow-management" --include="*.md" --include="*.sh" --include="*.yaml" workflows/ skills/ scripts/ .claude/skills/ 2>/dev/null | head -1; then
  fail "case 30 — at least one source file still has '# owner: workflow-management'"
fi
ok "case 30 — no orphan workflow-management owner headers"

# Case 31: governance/architecture docs no longer reference Path A/B
for f in CLAUDE.md CLAUDE.public.md docs/templates/CLAUDE.md docs/templates/PRINCIPLES.md docs/ARCHITECTURE.md; do
  if grep -q "Path A\|Path B" "$f"; then
    fail "case 31 — $f still references Path A or Path B"
  fi
done
ok "case 31 — no Path A/B references in project memory or architecture docs"

# Case 32: /cleanup asks before closing tracker items and delegates mutation
# through the non-interactive helper.
CLEANUP="skills/cleanup/SKILL.md"
grep -q "AskUserQuestion" "$CLEANUP" \
  || fail "case 32 — /cleanup does not use AskUserQuestion for tracker-close confirmation"
grep -q "scripts/cleanup-tracker-closure.sh classify" "$CLEANUP" \
  || fail "case 32 — /cleanup does not delegate classification to cleanup-tracker-closure.sh"
grep -q "scripts/cleanup-tracker-closure.sh close" "$CLEANUP" \
  || fail "case 32 — /cleanup does not delegate confirmed close to cleanup-tracker-closure.sh"
grep -q -- "--confirm-close" "$CLEANUP" \
  || fail "case 32 — /cleanup close path does not require --confirm-close"
grep -q "roadmap_tracker_issue_close" "$CLEANUP" \
  || fail "case 32 — /cleanup does not preserve the backend-neutral close helper requirement"
grep -q 'Never call provider-specific close or work-item mutation commands directly' "$CLEANUP" \
  || fail "case 32 — /cleanup does not prohibit raw provider close commands"
grep -q 'untrusted display data' "$CLEANUP" \
  || fail "case 32 — /cleanup does not treat tracker display fields as untrusted data"
ok "case 32 — /cleanup tracker-close prompt and helper delegation present"

# === Agent pipeline contract invariants ===

# Case 33: root and template ARBORETUM.md contracts exist
[ -f "ARBORETUM.md" ] || fail "case 33 - ARBORETUM.md missing"
[ -f "docs/templates/ARBORETUM.md" ] || fail "case 33 - docs/templates/ARBORETUM.md missing"
ok "case 33 - ARBORETUM.md contract files present"

# Case 34: ARBORETUM.md has common and adapter sections
for section in COMMON CODEX CLAUDE DATABRICKS; do
  grep -q "^## $section$" ARBORETUM.md \
    || fail "case 34 - ARBORETUM.md missing $section section"
done
ok "case 34 - ARBORETUM.md has common and adapter sections"

# Case 35: ARBORETUM.md states the common workflow contract
grep -q 'File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.' ARBORETUM.md \
  || fail "case 35 - ARBORETUM.md missing file-changing-work /start contract"
grep -q 'Everything-else work stops after `/design` for human review before `/build`.' ARBORETUM.md \
  || fail "case 35 - ARBORETUM.md missing review-before-build contract"
grep -q 'Only verified `agent-ready` work skips the review-before-build pause.' ARBORETUM.md \
  || fail "case 35 - ARBORETUM.md missing verified agent-ready exception"
grep -q "pipeline-state tracking remains the observable state layer" ARBORETUM.md \
  || fail "case 35 - ARBORETUM.md missing pipeline-state boundary"
ok "case 35 - ARBORETUM.md states the common workflow contract"

# Case 36: tool entrypoints point to ARBORETUM.md and repeat the local tripwire
for f in CLAUDE.md AGENTS.md CLAUDE.public.md docs/templates/CLAUDE.md docs/templates/AGENTS.md; do
  grep -q "ARBORETUM.md" "$f" \
    || fail "case 36 - $f does not point to ARBORETUM.md"
  grep -q 'File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.' "$f" \
    || fail "case 36 - $f missing local file-changing-work tripwire"
  grep -q 'Everything-else work stops after `/design` for human review before `/build`.' "$f" \
    || fail "case 36 - $f missing local review-before-build tripwire"
  grep -q 'Only verified `agent-ready` work skips the review-before-build pause.' "$f" \
    || fail "case 36 - $f missing local verified agent-ready exception"
done
ok "case 36 - tool entrypoints point to ARBORETUM.md and repeat the tripwire"

# Case 37: stage prose states the review-before-build pause
grep -q 'Only verified `agent-ready` work may skip the review-before-build pause.' "$START" \
  || fail "case 37 - /start missing verified agent-ready review-pause rule"
grep -q 'Before exiting to `/build`, stop for human review of the design package.' "$DESIGN" \
  || fail "case 37 - /design missing design-package review pause"
grep -q 'Do not log `/design exited` or hand off to `/build` until that approval has' "$DESIGN" \
  || fail "case 37 - /design does not keep stage exit logging behind human approval"
grep -q "everything-else -> /design -> human review -> /build" workflows/build.md \
  || fail "case 37 - build workflow missing human review transition"
ok "case 37 - stage prose states the review-before-build pause"

# Case 38: AGENTS.md no longer presents legacy workflows as the active lifecycle
for legacy in feature bug-fix refactor documentation; do
  if grep -q "| \\*\\*$legacy\\*\\* |" AGENTS.md; then
    fail "case 38 - AGENTS.md still lists legacy workflow as active: $legacy"
  fi
done
ok "case 38 - AGENTS.md legacy active workflow rows absent"

# Case 39: project entrypoints point agents at workflow stage sections, not a
# stale Flow-only heading that no longer exists on every workflow.
for f in AGENTS.md CLAUDE.md; do
  if grep -q 'Parse only `## Flow` sections' "$f"; then
    fail "case 39 - $f still instructs agents to parse only ## Flow sections"
  fi
  grep -q '## Stages.*## Flow' "$f" \
    || fail "case 39 - $f does not mention the ## Stages/## Flow fallback"
done
ok "case 39 - project entrypoints use stage/flow workflow section guidance"

echo "ALL PASS: skill-prose v2 invariants"
