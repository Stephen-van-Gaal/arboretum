#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-contract-health-check.sh — Contract test for
# docs/contracts/health-check.contract.md. Asserts HC-1..HC-10
# from the contract's ## Test surface against scripts/health-check.sh.
#
# Uses the fixture-project pattern: mktemp -d a project skeleton,
# populate docs/specs/ + docs/REGISTER.md + (sometimes)
# roadmap.config.yaml, then invoke scripts/health-check.sh against
# the fixture via PROJECT_DIR isolation (HC-6).
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
#
# Closes #176 (HC-4 active-empty-owns + governs-narrative discipline)
# as non-recurrable by construction.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC="$SCRIPT_DIR/health-check.sh"

[ -f "$HC" ] || { echo "FAIL: $HC not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
MINI_FIXTURE=$(mktemp -d)
UNRELATED_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$MINI_FIXTURE" "$UNRELATED_DIR"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── Build the main fixture project ───────────────────────────────────

mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/docs/definitions" "$FIXTURE/src" "$FIXTURE/workflows"

# Required governed documents for Check 1 (per scripts/health-check.sh:541-547):
# workflows/README.md, CLAUDE.md, docs/ARCHITECTURE.md, docs/REGISTER.md,
# contracts.yaml, docs/definitions/, docs/specs/ must all be present.
touch "$FIXTURE/CLAUDE.md"
touch "$FIXTURE/contracts.yaml"
touch "$FIXTURE/workflows/README.md"
touch "$FIXTURE/docs/ARCHITECTURE.md"

# Spec 1: canonical baseline — active + owns non-empty
cat > "$FIXTURE/docs/specs/alpha.spec.md" <<'INNER'
---
name: alpha
status: active
owner: architecture
owns:
  - src/alpha.py
---

# alpha
INNER

# Spec 2: status=draft — Check 6 status-enum (silent for valid)
cat > "$FIXTURE/docs/specs/beta.spec.md" <<'INNER'
---
name: beta
status: draft
owner: architecture
owns:
  - src/beta.py
---

# beta
INNER

# Spec 3: HC-4 escape branch — active+owns:[]+governs-narrative
cat > "$FIXTURE/docs/specs/gamma-narrative.spec.md" <<'INNER'
---
name: gamma-narrative
status: active
owner: architecture
owns: []
governs-narrative: docs/SHARED.md §3 Gamma Narrative
---

# gamma-narrative
INNER

# Spec 4: HC-4 violation branch — active+owns:[]+no-governs-narrative
cat > "$FIXTURE/docs/specs/delta-violator.spec.md" <<'INNER'
---
name: delta-violator
status: active
owner: architecture
owns: []
---

# delta-violator (deliberately violates Check 6 active-empty-owns invariant)
INNER

# Spec 4b: HC-4 bypass-attempt branch — active+owns:[]+governs-narrative-as-yaml-comment
# YAML treats `governs-narrative: # TODO` as having an empty scalar value (the `#`
# starts an inline comment, so the value before it is empty). Without the
# trailing-comment-strip in the awk parser, this would extract `# TODO` and be
# treated as non-empty (info branch instead of warn). Codex caught this in PR
# #356 review; HC-4 asserts the bypass attempt still triggers the ✗ warn.
cat > "$FIXTURE/docs/specs/delta-comment-bypass.spec.md" <<'INNER'
---
name: delta-comment-bypass
status: active
owner: architecture
owns: []
governs-narrative: # TODO — left as a comment to test the strip
---

# delta-comment-bypass (governs-narrative is a YAML inline-comment only;
# value is semantically empty; bypass attempt must still trigger ✗)
INNER

# Spec 4c: HC-4 bypass-attempt branch — active+owns:[]+governs-narrative-is-yaml-null
# YAML treats `null` (and the YAML-spec equivalent `~`) as semantically empty.
# Without the null/~ normalization in the case statement after the awk parse,
# this spec would extract the literal "null" string (truthy under [ -n ]) and
# bypass the strict-warn branch. Codex round-3 finding; same bypass class as
# delta-comment-bypass (#356).
cat > "$FIXTURE/docs/specs/delta-null-bypass.spec.md" <<'INNER'
---
name: delta-null-bypass
status: active
owner: architecture
owns: []
governs-narrative: null
---

# delta-null-bypass (governs-narrative is YAML null; semantically empty;
# bypass attempt must still trigger ✗)
INNER

# Spec 5: HC-3 extended-enum coverage — unconfigured project, unknown status
cat > "$FIXTURE/docs/specs/epsilon-extended.spec.md" <<'INNER'
---
name: epsilon-extended
status: ready
owner: architecture
owns:
  - src/epsilon.py
---

# epsilon-extended (uses non-canonical 'ready' status)
INNER

# Source files referenced by owns: lists
echo "# owner: alpha"             > "$FIXTURE/src/alpha.py"
echo "# owner: beta"              > "$FIXTURE/src/beta.py"
echo "# owner: epsilon-extended"  > "$FIXTURE/src/epsilon.py"

# REGISTER.md — minimal 4-column Spec Index covering all five specs.
cat > "$FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|
| alpha.spec.md | active | architecture | src/alpha.py |
| beta.spec.md | draft | architecture | src/beta.py |
| gamma-narrative.spec.md | active | architecture | — |
| delta-violator.spec.md | active | architecture | — |
| delta-comment-bypass.spec.md | active | architecture | — |
| delta-null-bypass.spec.md | active | architecture | — |
| epsilon-extended.spec.md | ready | architecture | src/epsilon.py |

## Status Summary

| Status | Count |
|--------|-------|
| active | 3 |
| draft | 1 |
| ready | 1 |

## Unowned Code

## Dependency Resolution Order
INNER

# ── HC-1: output-format-stability ────────────────────────────────────

MAIN_OUT=$(bash "$HC" "$FIXTURE" 2>&1 || true)

for n in 1 6 7 9; do
  if echo "$MAIN_OUT" | grep -qE "^━━━ Check $n:"; then
    pass "HC-1: Check $n header line present"
  else
    fail_case "HC-1: Check $n header line missing" "$MAIN_OUT"
  fi
done

# ── HC-3: status-enum invariant (extended enum, default project) ─────

if echo "$MAIN_OUT" | grep -qF "Project uses extended status enum"; then
  pass "HC-3: extended-enum aggregation line present (status 'ready' surfaced)"
else
  fail_case "HC-3: expected extended-enum info line missing" "$MAIN_OUT"
fi

# ── HC-4: active-owns-discipline ─────────────────────────────────────

if echo "$MAIN_OUT" | grep -qE "·.*gamma-narrative.*governs narrative: docs/SHARED.md §3 Gamma Narrative"; then
  pass "HC-4: gamma-narrative emits info with citation"
else
  fail_case "HC-4: gamma-narrative info-with-citation line missing" "$(echo "$MAIN_OUT" | grep gamma-narrative)"
fi

if echo "$MAIN_OUT" | grep -qE "✗.*delta-violator.*no governs-narrative declared"; then
  pass "HC-4: delta-violator emits ✗ contradiction line"
else
  fail_case "HC-4: delta-violator ✗ contradiction line missing" "$(echo "$MAIN_OUT" | grep delta-violator)"
fi

# HC-4 also pins the YAML-comment bypass: a spec with `governs-narrative: # TODO`
# (where the value is semantically empty per YAML inline-comment rules) must
# still trigger the ✗ warn — the awk parser strips trailing `[[:space:]]*#.*$`
# before testing -n. Codex caught the missing strip in PR #356 review.
if echo "$MAIN_OUT" | grep -qE "✗.*delta-comment-bypass.*no governs-narrative declared"; then
  pass "HC-4: delta-comment-bypass (governs-narrative=YAML-comment-only) emits ✗ contradiction line"
else
  fail_case "HC-4: delta-comment-bypass should be treated as no-governs-narrative (YAML inline comment makes value empty)" "$(echo "$MAIN_OUT" | grep delta-comment-bypass)"
fi

# HC-4 also pins the YAML-null bypass: a spec with `governs-narrative: null`
# (or `governs-narrative: ~`) is YAML-semantically empty. The `case` statement
# after the awk extraction normalizes these spellings to "" so the strict-warn
# branch fires. Codex round-3 finding (same bypass class as comment-only).
if echo "$MAIN_OUT" | grep -qE "✗.*delta-null-bypass.*no governs-narrative declared"; then
  pass "HC-4: delta-null-bypass (governs-narrative=YAML-null) emits ✗ contradiction line"
else
  fail_case "HC-4: delta-null-bypass should be treated as no-governs-narrative (YAML null spelling)" "$(echo "$MAIN_OUT" | grep delta-null-bypass)"
fi

# ── HC-2: exit-code contract ─────────────────────────────────────────

bash "$HC" "$FIXTURE" >/dev/null 2>&1
exit_with_violator=$?
if [ "$exit_with_violator" -eq 1 ]; then
  pass "HC-2: fixture with delta-violator exits 1"
else
  fail_case "HC-2: expected exit 1 with violator, got $exit_with_violator"
fi

# Now remove ALL THREE violators (delta-violator + delta-comment-bypass +
# delta-null-bypass) and verify exit 0 — the gamma-narrative spec stays
# (HC-4 GREEN-branch with a real governs-narrative value).
rm "$FIXTURE/docs/specs/delta-violator.spec.md" "$FIXTURE/docs/specs/delta-comment-bypass.spec.md" "$FIXTURE/docs/specs/delta-null-bypass.spec.md"
# Remove their rows from REGISTER.md too.
sed -i.bak \
  -e '/delta-violator.spec.md/d' \
  -e '/delta-comment-bypass.spec.md/d' \
  -e '/delta-null-bypass.spec.md/d' \
  "$FIXTURE/docs/REGISTER.md" && rm "$FIXTURE/docs/REGISTER.md.bak"

bash "$HC" "$FIXTURE" >/dev/null 2>&1
exit_clean=$?
if [ "$exit_clean" -eq 0 ]; then
  pass "HC-2: fixture without violator exits 0"
else
  CLEAN_OUT=$(bash "$HC" "$FIXTURE" 2>&1 || true)
  fail_case "HC-2: expected exit 0 after removing violator, got $exit_clean" "$CLEAN_OUT"
fi

# ── HC-2 (S2 #641): three-level severity exit code ───────────────────
#
# The fixture is now clean (violators removed → exit 0). Advisory checks
# 5/7/9 cannot fire on it: contracts.yaml is empty (no pins → no Check 5
# staleness), the fixture is not a git repo (Check 7 skips), and there is
# no roadmap.config.yaml (Check 9 skips). So a single advisory finding can
# be isolated via Check 8 (test-prudent plan without a ## Tests section).
mkdir -p "$FIXTURE/docs/plans"
cat > "$FIXTURE/docs/plans/advisory-only.md" <<'INNER'
# Plan: advisory-only fixture

This plan will implement and modify src/alpha.py. It deliberately omits a
Tests section so Check 8 flags it as a test-prudent plan without ## Tests.
INNER

bash "$HC" "$FIXTURE" >/dev/null 2>&1
exit_advisory=$?
if [ "$exit_advisory" -eq 2 ]; then
  pass "HC-2: advisory-only findings (Check 8) exit 2"
else
  ADV_OUT=$(bash "$HC" "$FIXTURE" 2>&1 || true)
  fail_case "HC-2: expected exit 2 for advisory-only finding, got $exit_advisory" "$ADV_OUT"
fi

# Precedence: a blocking finding alongside the advisory one → exit 1 (blocking
# wins). Remove a required governed document to trigger Check 1 (blocking).
mv "$FIXTURE/workflows/README.md" "$FIXTURE/workflows/README.md.hidden"
bash "$HC" "$FIXTURE" >/dev/null 2>&1
exit_precedence=$?
if [ "$exit_precedence" -eq 1 ]; then
  pass "HC-2: blocking finding wins over advisory (exit 1)"
else
  PREC_OUT=$(bash "$HC" "$FIXTURE" 2>&1 || true)
  fail_case "HC-2: expected exit 1 when blocking+advisory both present, got $exit_precedence" "$PREC_OUT"
fi
# Restore the clean fixture state for downstream assertions.
mv "$FIXTURE/workflows/README.md.hidden" "$FIXTURE/workflows/README.md"
rm -f "$FIXTURE/docs/plans/advisory-only.md"

# ── HC-6: PROJECT_DIR-isolation ──────────────────────────────────────
#
# Caller's CWD differs from PROJECT_DIR. Three assertions per Codex
# feedback on the initial weak version:
#   (1) $UNRELATED_DIR (caller CWD) MUST NOT appear in stdout — direct
#       leakage check.
#   (2) Isolated run's exit code MUST match same-CWD baseline run.
#       Catches the "ignores $FIXTURE arg, uses script's own repo paths"
#       regression class (different file state → different exit code).
#   (3) Isolated stdout MUST be byte-identical to same-CWD baseline
#       stdout (with $UNRELATED_DIR stripped if it ever appears). Any
#       behaviour divergence means the script is consulting CWD.

BASELINE_OUT=$(bash "$HC" "$FIXTURE" 2>&1)
baseline_exit=$?

ISOLATED_OUT=$(cd "$UNRELATED_DIR" && bash "$HC" "$FIXTURE" 2>&1)
isolated_exit=$?

if echo "$ISOLATED_OUT" | grep -qF "$UNRELATED_DIR"; then
  fail_case "HC-6 (1): $UNRELATED_DIR leaked into output despite PROJECT_DIR arg" "$(echo "$ISOLATED_OUT" | grep -F "$UNRELATED_DIR" | head -5)"
else
  pass "HC-6 (1): no leakage of caller CWD ($UNRELATED_DIR) into output"
fi

if [ "$isolated_exit" -eq "$baseline_exit" ]; then
  pass "HC-6 (2): isolated exit code ($isolated_exit) matches baseline ($baseline_exit)"
else
  fail_case "HC-6 (2): isolated exit $isolated_exit ≠ baseline exit $baseline_exit (script is consulting CWD)"
fi

if [ "$BASELINE_OUT" = "$ISOLATED_OUT" ]; then
  pass "HC-6 (3): isolated stdout matches baseline stdout byte-for-byte"
else
  fail_case "HC-6 (3): isolated stdout diverges from baseline" "$(diff <(echo "$BASELINE_OUT") <(echo "$ISOLATED_OUT") | head -20)"
fi

# HC-6 (4): positive assertion that the fixture path IS in the output.
# Codex round-3 caught that (1)+(2)+(3) together still pass if the script
# silently ignored the PROJECT_DIR arg and used script-checkout paths
# (identical baseline/isolated, no $UNRELATED_DIR leak). Check 7 emits a
# fixture-rooted path on the "not a git working tree" skip line (the
# fixture isn't a git repo). If $FIXTURE doesn't appear there, the
# script isn't actually consulting the arg.
if echo "$ISOLATED_OUT" | grep -qF "$FIXTURE"; then
  pass "HC-6 (4): \$FIXTURE path appears in output (script is consulting the PROJECT_DIR arg)"
else
  fail_case "HC-6 (4): \$FIXTURE path missing from output — script may be ignoring PROJECT_DIR arg" "$ISOLATED_OUT"
fi

# ── HC-7: Check-9 roadmap-config gating (negative case) ──────────────
#
# Main fixture has no roadmap.config.yaml. Per scripts/health-check.sh:1190,
# the wrapper emits exactly one info line `· Skipped — roadmap.config.yaml
# not present` when strategic_anchor_check returns empty. So assertion is:
# zero ✗ warn lines inside the Check 9 section (the `· Skipped` info line
# is expected and allowed). Extraction uses `sed` with a more specific end
# pattern so the start `━━━ Check 9:` line is excluded from the range
# (Codex/Copilot caught the original awk's self-terminating range bug).
MAIN_OUT_CLEAN=$(bash "$HC" "$FIXTURE" 2>&1 || true)
CHECK9_BLOCK=$(echo "$MAIN_OUT_CLEAN" | awk '
  /^━━━ Check 9:/ { in_block=1; next }
  /^━━━ Check [0-9]/ && in_block { exit }
  in_block { print }
')
CHECK9_WARNS=$(echo "$CHECK9_BLOCK" | grep -cE "^  ✗" || true)
if [ "$CHECK9_WARNS" -eq 0 ]; then
  pass "HC-7 (negative): Check 9 emits 0 ✗ warn lines when roadmap.config.yaml absent"
else
  fail_case "HC-7 (negative): expected 0 ✗ warn lines in Check 9 without roadmap.config.yaml, got $CHECK9_WARNS" "$CHECK9_BLOCK"
fi
# Also confirm the expected info line IS present (positive signal that
# the skipped path executed, not that Check 9 was suppressed entirely).
if echo "$CHECK9_BLOCK" | grep -qF "Skipped — roadmap.config.yaml not present"; then
  pass "HC-7 (negative): Check 9 emits the expected '· Skipped — ...' info line"
else
  fail_case "HC-7 (negative): expected '· Skipped — roadmap.config.yaml not present' info line missing" "$CHECK9_BLOCK"
fi

# ── HC-7: Check-9 roadmap-config gating (positive case) ──────────────
#
# Mini fixture has roadmap.config.yaml + Strategic Anchor in CLAUDE.md.
# Must also include the FULL Check 1 prerequisite set (workflows/README.md,
# CLAUDE.md, docs/ARCHITECTURE.md, docs/REGISTER.md, contracts.yaml,
# docs/definitions/, docs/specs/) — Codex caught that an earlier draft
# missed these, so Check 1 would emit ✗ lines and the assertion that
# Check 9 emits ✓ would mask a Check-1 failure that drives exit 1.
mkdir -p "$MINI_FIXTURE/docs/specs" "$MINI_FIXTURE/docs/definitions" "$MINI_FIXTURE/workflows"
touch "$MINI_FIXTURE/contracts.yaml"
touch "$MINI_FIXTURE/workflows/README.md"
touch "$MINI_FIXTURE/docs/ARCHITECTURE.md"

cat > "$MINI_FIXTURE/roadmap.config.yaml" <<'INNER'
profile: lean
components:
  - framework
INNER

cat > "$MINI_FIXTURE/CLAUDE.md" <<'INNER'
# CLAUDE.md (mini fixture)

## Strategic Anchor

**Time horizon:** Through 2099-Q4 (next review: 2099-12-31)

**In scope:**
- Mini fixture test

**Out of scope:**
- Anything else
INNER

# Minimal REGISTER.md so Checks 2/3/6/7 don't error out.
cat > "$MINI_FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|

## Status Summary

| Status | Count |
|--------|-------|

## Unowned Code

## Dependency Resolution Order
INNER

# Run without `|| true` so we can capture the real exit code — Codex
# caught that masking the exit status meant HC-7's exit-code half was
# never enforced.
MINI_OUT=$(bash "$HC" "$MINI_FIXTURE" 2>&1)
mini_exit=$?

# Extract Check 9 block via the same stateful awk pattern (header-exclusive
# range with specific end pattern) used in the negative case.
MINI_CHECK9_BLOCK=$(echo "$MINI_OUT" | awk '
  /^━━━ Check 9:/ { in_block=1; next }
  /^━━━ Check [0-9]/ && in_block { exit }
  in_block { print }
')

if echo "$MINI_CHECK9_BLOCK" | grep -qE "^  ✓"; then
  pass "HC-7 (positive): Check 9 emits ✓ with bold Strategic Anchor scope labels"
else
  fail_case "HC-7 (positive): expected Check 9 ✓ line for bold Strategic Anchor scope labels" "$MINI_CHECK9_BLOCK"
fi

if echo "$MINI_CHECK9_BLOCK" | grep -q 'integer expression expected'; then
  fail_case "HC-7 (positive): bold Strategic Anchor scope labels must not trigger integer comparison errors" "$MINI_CHECK9_BLOCK"
else
  pass "HC-7 (positive): bold Strategic Anchor scope labels produce integer-safe bullet counts"
fi

if [ "$mini_exit" -eq 0 ]; then
  pass "HC-7 (positive): mini fixture exits 0 (all checks pass)"
else
  fail_case "HC-7 (positive): mini fixture expected exit 0, got $mini_exit" "$MINI_OUT"
fi

cat > "$MINI_FIXTURE/CLAUDE.md" <<'INNER'
# CLAUDE.md (mini fixture)

## Strategic Anchor

**Time horizon:** Through 2099-Q4 (next review: 2099-12-31)

**In scope:**

**Out of scope:**
INNER

EMPTY_SCOPE_OUT=$(bash "$HC" "$MINI_FIXTURE" 2>&1)
empty_scope_exit=$?

EMPTY_SCOPE_CHECK9_BLOCK=$(echo "$EMPTY_SCOPE_OUT" | awk '
  /^━━━ Check 9:/ { in_block=1; next }
  /^━━━ Check [0-9]/ && in_block { exit }
  in_block { print }
')

if echo "$EMPTY_SCOPE_CHECK9_BLOCK" | grep -q "In scope"; then
  pass "HC-7 (negative): bold In scope label with no bullets emits a warning"
else
  fail_case "HC-7 (negative): expected warning for empty bold In scope section" "$EMPTY_SCOPE_CHECK9_BLOCK"
fi

if echo "$EMPTY_SCOPE_CHECK9_BLOCK" | grep -q "Out of scope"; then
  pass "HC-7 (negative): bold Out of scope label with no bullets emits a warning"
else
  fail_case "HC-7 (negative): expected warning for empty bold Out of scope section" "$EMPTY_SCOPE_CHECK9_BLOCK"
fi

if [ "$empty_scope_exit" -ne 0 ]; then
  pass "HC-7 (negative): empty bold scope fixture exits non-zero"
else
  fail_case "HC-7 (negative): empty bold scope fixture expected non-zero exit" "$EMPTY_SCOPE_OUT"
fi

# ── HC-5: Check 7 read-only default ──────────────────────────────────

# Build a git-tracked sub-fixture where a spec's owned file commits
# strictly after the spec — drift Check 7 should detect.
DRIFT_FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$MINI_FIXTURE" "$UNRELATED_DIR" "$DRIFT_FIXTURE"' EXIT

mkdir -p "$DRIFT_FIXTURE/docs/specs" "$DRIFT_FIXTURE/docs/definitions" "$DRIFT_FIXTURE/src" "$DRIFT_FIXTURE/workflows"
# Check 1 prerequisites (same set as the main + mini fixtures).
touch "$DRIFT_FIXTURE/CLAUDE.md" "$DRIFT_FIXTURE/contracts.yaml"
touch "$DRIFT_FIXTURE/workflows/README.md"
touch "$DRIFT_FIXTURE/docs/ARCHITECTURE.md"

# Initialise git so health-check's `git log` calls in Check 7 work.
(cd "$DRIFT_FIXTURE" && git init -q && git config user.email "t@t" && git config user.name "t")

cat > "$DRIFT_FIXTURE/docs/specs/zeta.spec.md" <<'INNER'
---
name: zeta
status: active
owner: architecture
owns:
  - src/zeta.py
---

# zeta
INNER

# Real (non-comment) content so the drift commit below is a behaviour
# change — a comment/whitespace/frontmatter-only edit is benign under
# Check 7's content-aware classifier (#238) and would not flag (see HC-9).
printf '# owner: zeta\ndef z():\n    return 1\n' > "$DRIFT_FIXTURE/src/zeta.py"

cat > "$DRIFT_FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|
| zeta.spec.md | active | architecture | src/zeta.py |

## Status Summary

| Status | Count |
|--------|-------|
| active | 1 |

## Unowned Code

## Dependency Resolution Order
INNER

# Commit spec + baseline code first, then a behaviour change second —
# that's the drift order (and the change must be non-benign to flag).
(cd "$DRIFT_FIXTURE" && git add docs/specs/zeta.spec.md docs/REGISTER.md src/zeta.py && git commit -q -m "spec")
(cd "$DRIFT_FIXTURE" && printf '# owner: zeta\ndef z():\n    return 2\n' > src/zeta.py && git add src/zeta.py && git commit -q -m "drift: behaviour change")

# Snapshot pre-run state of spec frontmatter and REGISTER row.
PRE_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
PRE_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

# Capture exit code on read-only run — advisory drift exists (Check 7 is
# advisory, S2 #641), so exit must be 2.
bash "$HC" "$DRIFT_FIXTURE" >/dev/null 2>&1
readonly_exit=$?

POST_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
POST_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

if [ "$PRE_SPEC" = "$POST_SPEC" ] && [ "$PRE_REG" = "$POST_REG" ]; then
  pass "HC-5: Check 7 without --reconcile leaves spec + REGISTER byte-identical"
else
  fail_case "HC-5: Check 7 mutated state without --reconcile" "spec: $PRE_SPEC -> $POST_SPEC | register: $PRE_REG -> $POST_REG"
fi
if [ "$readonly_exit" -eq 2 ]; then
  pass "HC-5: Check 7 read-only run exits 2 (advisory drift present)"
else
  fail_case "HC-5: Check 7 read-only run expected exit 2 (advisory drift), got $readonly_exit"
fi

# Capture exit code on --reconcile --all run. Per HC-2 contract:
# "--reconcile does not change exit-code semantics." Check 7 is an advisory
# check (S2 #641), so even after the auto-flip it still emits a ⚠ drift line
# and exits 2 (the script doesn't suppress findings just because it mutated).
# Codex round-3 caught the missing exit-code assertion (the original `|| true`
# masked any regression where --reconcile dropped the finding along with the
# flip). #750: this fixture is a single commit-chain with no feature branch,
# so HEAD == integration base and the default-scoped --reconcile correctly
# flips nothing; --all opts into the repo-wide flip to exercise the
# scope-independent mutation mechanics here (branch-scoping is pinned by HC-10).
bash "$HC" --reconcile --all "$DRIFT_FIXTURE" >/dev/null 2>&1
reconcile_exit=$?

RECONCILED_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
RECONCILED_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

if echo "$RECONCILED_SPEC" | grep -qE "status:[[:space:]]+stale" && echo "$RECONCILED_REG" | grep -qF "stale"; then
  pass "HC-5: Check 7 with --reconcile --all flips spec frontmatter AND REGISTER row to stale"
else
  fail_case "HC-5: Check 7 --reconcile --all did not flip both surfaces" "spec: $RECONCILED_SPEC | register: $RECONCILED_REG"
fi
if [ "$reconcile_exit" -eq 2 ]; then
  pass "HC-5: Check 7 --reconcile --all run still exits 2 (advisory drift findings independent of mutation)"
else
  fail_case "HC-5: Check 7 --reconcile --all expected exit 2 (per HC-2 contract: --reconcile doesn't change exit-code semantics), got $reconcile_exit"
fi

# ── HC-9: Check 7 content-aware — benign diff does NOT flag ───────────
BENIGN_FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$MINI_FIXTURE" "$UNRELATED_DIR" "$DRIFT_FIXTURE" "$BENIGN_FIXTURE"' EXIT
mkdir -p "$BENIGN_FIXTURE/docs/specs" "$BENIGN_FIXTURE/docs/definitions" "$BENIGN_FIXTURE/src" "$BENIGN_FIXTURE/workflows"
touch "$BENIGN_FIXTURE/CLAUDE.md" "$BENIGN_FIXTURE/contracts.yaml" "$BENIGN_FIXTURE/workflows/README.md" "$BENIGN_FIXTURE/docs/ARCHITECTURE.md"
(cd "$BENIGN_FIXTURE" && git init -q && git config user.email t@t && git config user.name t)
cat > "$BENIGN_FIXTURE/docs/specs/eta.spec.md" <<'INNER'
---
name: eta
status: active
owner: architecture
owns:
  - src/eta.py
---

# eta
INNER
printf '# owner: eta\ndef e():\n    return 1\n' > "$BENIGN_FIXTURE/src/eta.py"
cat > "$BENIGN_FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|
| eta.spec.md | active | architecture | src/eta.py |

## Status Summary

| Status | Count |
|--------|-------|
| active | 1 |

## Unowned Code

## Dependency Resolution Order
INNER
(cd "$BENIGN_FIXTURE" && git add docs/specs/eta.spec.md docs/REGISTER.md src/eta.py && git commit -q -m "baseline")
# Benign drift: add a comment line only, committed after the spec.
(cd "$BENIGN_FIXTURE" && printf '# owner: eta\n# benign note\ndef e():\n    return 1\n' > src/eta.py && git add src/eta.py && git commit -q -m "comment only")

PRE_ETA=$(grep "^status:" "$BENIGN_FIXTURE/docs/specs/eta.spec.md")
benign_out=$(bash "$HC" "$BENIGN_FIXTURE" 2>&1)
POST_ETA=$(grep "^status:" "$BENIGN_FIXTURE/docs/specs/eta.spec.md")

if printf '%s\n' "$benign_out" | grep -q 'eta.spec.md: drift detected'; then
  fail_case "HC-9: benign comment-only change flagged as drift" "$benign_out"
elif [ "$PRE_ETA" != "$POST_ETA" ]; then
  fail_case "HC-9: benign change mutated spec status" "$PRE_ETA -> $POST_ETA"
else
  pass "HC-9: content-aware Check 7 passes a benign diff (no flag, no mutation)"
fi

# ── HC-10: Check 7 --reconcile branch-scope (#750) ───────────────────
#
# Fixture: a local 'main' with TWO active specs (a owns src/a.py, b owns
# src/b.py), both drifted by a post-spec behaviour-change commit on main; then a
# feature branch whose only further commit changes src/a.py (b is main-only
# drift the branch never touched). Asserts: (1) default --reconcile flips only
# in-scope spec a + surfaces b as an out-of-scope advisory; (2) --reconcile
# --all flips both; (3) on main (merge-base == HEAD) nothing flips + advises.
SCOPE_FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$MINI_FIXTURE" "$UNRELATED_DIR" "$DRIFT_FIXTURE" "$BENIGN_FIXTURE" "$SCOPE_FIXTURE"' EXIT
SG() { git -C "$SCOPE_FIXTURE" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$SCOPE_FIXTURE/docs/specs" "$SCOPE_FIXTURE/docs/definitions" "$SCOPE_FIXTURE/src" "$SCOPE_FIXTURE/workflows"
touch "$SCOPE_FIXTURE/CLAUDE.md" "$SCOPE_FIXTURE/contracts.yaml" "$SCOPE_FIXTURE/workflows/README.md" "$SCOPE_FIXTURE/docs/ARCHITECTURE.md"
for s in a b; do
  cat > "$SCOPE_FIXTURE/docs/specs/$s.spec.md" <<INNER
---
name: $s
status: active
owner: architecture
owns:
  - src/$s.py
---

# $s
INNER
  printf '# owner: %s\ndef %s():\n    return 1\n' "$s" "$s" > "$SCOPE_FIXTURE/src/$s.py"
done
cat > "$SCOPE_FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|
| a.spec.md | active | architecture | src/a.py |
| b.spec.md | active | architecture | src/b.py |

## Status Summary

| Status | Count |
|--------|-------|
| active | 2 |

## Unowned Code

## Dependency Resolution Order
INNER
SG init -q
SG branch -M main
SG add docs/specs/a.spec.md docs/specs/b.spec.md docs/REGISTER.md src/a.py src/b.py
SG commit -q -m "specs a,b active"
# Drift BOTH owned files on main (behaviour change, after the specs' commit).
printf '# owner: a\ndef a():\n    return 2\n' > "$SCOPE_FIXTURE/src/a.py"
printf '# owner: b\ndef b():\n    return 2\n' > "$SCOPE_FIXTURE/src/b.py"
SG add src/a.py src/b.py; SG commit -q -m "drift a and b on main"
# Feature branch: change ONLY a.py further (b stays main-only drift).
SG checkout -q -b feat/scope
printf '# owner: a\ndef a():\n    return 3\n' > "$SCOPE_FIXTURE/src/a.py"
SG add src/a.py; SG commit -q -m "feature: touch a only"

sc_status() { grep '^status:' "$SCOPE_FIXTURE/docs/specs/$1.spec.md"; }
sc_reset() { SG checkout HEAD -- docs/specs/a.spec.md docs/specs/b.spec.md docs/REGISTER.md; }

# (1) default --reconcile on the feature branch → only a flips, b surfaced.
scope_out=$(bash "$HC" --reconcile "$SCOPE_FIXTURE" 2>&1)
if echo "$(sc_status a)" | grep -qE "status:[[:space:]]+stale" \
   && echo "$(sc_status b)" | grep -qE "status:[[:space:]]+active" \
   && printf '%s\n' "$scope_out" | grep -qiE 'outside .*scope|out-of-scope|not flipped'; then
  pass "HC-10: default --reconcile flips in-scope spec only, surfaces out-of-scope drift"
else
  fail_case "HC-10: branch-scope default did not isolate the flip" "a=$(sc_status a) b=$(sc_status b) | $scope_out"
fi

# (2) --reconcile --all → both flip.
sc_reset
bash "$HC" --reconcile --all "$SCOPE_FIXTURE" >/dev/null 2>&1
if echo "$(sc_status a)" | grep -qE "status:[[:space:]]+stale" && echo "$(sc_status b)" | grep -qE "status:[[:space:]]+stale"; then
  pass "HC-10: --reconcile --all flips both specs (repo-wide opt-in)"
else
  fail_case "HC-10: --reconcile --all did not flip both" "a=$(sc_status a) b=$(sc_status b)"
fi

# (3) on main (merge-base == HEAD) → nothing flips, advises --all.
sc_reset
SG checkout -q main
mainscope_out=$(bash "$HC" --reconcile "$SCOPE_FIXTURE" 2>&1)
if echo "$(sc_status a)" | grep -qE "status:[[:space:]]+active" \
   && echo "$(sc_status b)" | grep -qE "status:[[:space:]]+active" \
   && printf '%s\n' "$mainscope_out" | grep -qiE 'no branch scope|--reconcile --all|repo-wide|integration branch'; then
  pass "HC-10: on-base --reconcile flips nothing and advises --all"
else
  fail_case "HC-10: on-base --reconcile did not stay read-only / advise" "a=$(sc_status a) b=$(sc_status b) | $mainscope_out"
fi

# (4) #750 finding A — --all without --reconcile is a reported no-op, no mutation.
sc_reset
alln_out=$(bash "$HC" --all "$SCOPE_FIXTURE" 2>&1)
if echo "$(sc_status a)" | grep -qE "status:[[:space:]]+active" \
   && printf '%s\n' "$alln_out" | grep -qiE 'no effect without --reconcile|all .*no effect'; then
  pass "HC-10: --all without --reconcile is a reported no-op (no mutation)"
else
  fail_case "HC-10: --all without --reconcile not reported / mutated" "a=$(sc_status a) | $alln_out"
fi

# (5) #750 finding C / HC-2 — a clean --reconcile on the integration branch
# exits 0 with no scope roll-up (scope resolution must not, by itself, make a
# clean run advisory). Touch+commit the specs so they out-date their owned
# files (no drift), then reconcile on main.
sc_reset
printf '\n<!-- reconciled -->\n' >> "$SCOPE_FIXTURE/docs/specs/a.spec.md"
printf '\n<!-- reconciled -->\n' >> "$SCOPE_FIXTURE/docs/specs/b.spec.md"
SG add docs/specs/a.spec.md docs/specs/b.spec.md >/dev/null 2>&1
SG commit -q -m "touch specs to clear drift" >/dev/null 2>&1
set +e; clean_out=$(bash "$HC" --reconcile "$SCOPE_FIXTURE" 2>&1); clean_rc=$?; set -e
if [ "$clean_rc" -eq 0 ] && ! printf '%s\n' "$clean_out" | grep -qiE 'not reconciled|outside .*scope|integration branch'; then
  pass "HC-10: clean --reconcile on integration branch exits 0, no scope roll-up"
else
  fail_case "HC-10: clean --reconcile on-base not exit-0/no-roll-up (HC-2, finding C)" "rc=$clean_rc | $clean_out"
fi

# ── HC-11 / HC-12: language-aware Check 3 (#859) ─────────────────────
# Self-contained Check-1-complete fixture: one active spec owning src/alpha.py.
mk_lang_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/docs/specs" "$d/docs/definitions" "$d/src" "$d/workflows"
  touch "$d/CLAUDE.md" "$d/contracts.yaml" "$d/docs/ARCHITECTURE.md" "$d/workflows/README.md"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  cat > "$d/docs/specs/alpha.spec.md" <<'INNER'
---
name: alpha
status: active
owner: architecture
owns:
  - src/alpha.py
---

# alpha
INNER
  printf '# owner: alpha\n' > "$d/src/alpha.py"
  printf '%s\n' "# Project Register" "" "## Spec Index" "" \
    "| Spec | Status | Owner | Owns (files/directories) |" \
    "|------|--------|-------|--------------------------|" \
    "| alpha.spec.md | active | architecture | src/alpha.py |" > "$d/docs/REGISTER.md"
  ( cd "$d" && git add -A && git commit -qm init )
  printf '%s\n' "$d"
}

# HC-11: source-languages-opt-in. Default scans only *.py; opt-in flags .ts.
LF="$(mk_lang_fixture)"
printf '// stray\n' > "$LF/src/stray.ts"; ( cd "$LF" && git add -A && git commit -qm ts )
set +e; def_out=$(bash "$HC" "$LF" 2>&1); def_rc=$?; set -e
printf 'source_languages:\n  - py\n  - ts\n' > "$LF/.arboretum.yml"
( cd "$LF" && git add -A && git commit -qm optin )
set +e; opt_out=$(bash "$HC" "$LF" 2>&1); opt_rc=$?; set -e
# Default must not *block-flag* the .ts (Half B scans only .py); a Half C
# advisory nudge about the undeclared .ts is expected and is exit 2, not 1.
if ! echo "$def_out" | grep -q "Unowned:.*stray.ts" && [ "$def_rc" != "1" ] \
   && echo "$opt_out" | grep -q "Unowned:.*stray.ts" && [ "$opt_rc" -eq 1 ]; then
  pass "HC-11: default does not block .ts (exit $def_rc); source_languages:[py,ts] flags it (exit 1)"
else
  fail_case "HC-11: source_languages opt-in/backward-compat" "def_rc=$def_rc opt_rc=$opt_rc | $opt_out"
fi
rm -rf "$LF"

# HC-12: undeclared-source-type discovery (advisory). One ⚠ nudge per ext,
# does not by itself produce exit 1; source_languages_ignore silences it.
LF="$(mk_lang_fixture)"
printf 'SELECT 1;\n' > "$LF/src/x.sql"; ( cd "$LF" && git add -A && git commit -qm sql )
set +e; disc_out=$(bash "$HC" "$LF" 2>&1); disc_rc=$?; set -e
printf 'source_languages_ignore:\n  - sql\n' > "$LF/.arboretum.yml"
( cd "$LF" && git add -A && git commit -qm ignore )
set +e; sil_out=$(bash "$HC" "$LF" 2>&1); set -e
if echo "$disc_out" | grep -q "sql.*not declared in source_languages" && [ "$disc_rc" != "1" ] \
   && ! echo "$sil_out" | grep -q "not declared in source_languages"; then
  pass "HC-12: undeclared .sql nudge is advisory (exit $disc_rc); ignore-list silences it"
else
  fail_case "HC-12: Half C discovery/advisory/ignore" "disc_rc=$disc_rc | $disc_out"
fi
rm -rf "$LF"

# ── Summary ──────────────────────────────────────────────────────────

if [ $fail -eq 0 ]; then
  echo "All health-check contract assertions passed (HC-1..HC-12)."
  exit 0
else
  echo "health-check contract test FAILED" >&2
  exit 1
fi
