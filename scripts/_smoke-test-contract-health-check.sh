#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-health-check.sh — Contract test for
# docs/contracts/health-check.contract.md. Asserts HC-1..HC-7
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

echo "# owner: zeta" > "$DRIFT_FIXTURE/src/zeta.py"

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

# Commit spec first, then owned-file mutation second — that's the drift order.
(cd "$DRIFT_FIXTURE" && git add docs/specs/zeta.spec.md docs/REGISTER.md && git commit -q -m "spec")
(cd "$DRIFT_FIXTURE" && echo "# owner: zeta — modified" > src/zeta.py && git add src/zeta.py && git commit -q -m "drift")

# Snapshot pre-run state of spec frontmatter and REGISTER row.
PRE_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
PRE_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

# Capture exit code on read-only run — drift exists, so exit must be 1.
bash "$HC" "$DRIFT_FIXTURE" >/dev/null 2>&1
readonly_exit=$?

POST_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
POST_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

if [ "$PRE_SPEC" = "$POST_SPEC" ] && [ "$PRE_REG" = "$POST_REG" ]; then
  pass "HC-5: Check 7 without --reconcile leaves spec + REGISTER byte-identical"
else
  fail_case "HC-5: Check 7 mutated state without --reconcile" "spec: $PRE_SPEC -> $POST_SPEC | register: $PRE_REG -> $POST_REG"
fi
if [ "$readonly_exit" -eq 1 ]; then
  pass "HC-5: Check 7 read-only run exits 1 (drift present)"
else
  fail_case "HC-5: Check 7 read-only run expected exit 1 (drift), got $readonly_exit"
fi

# Capture exit code on --reconcile run. Per HC-2 contract:
# "--reconcile does not change exit-code semantics." So even after the
# auto-flip Check 7 still emits a ✗ drift line and exits 1 (the script
# doesn't suppress findings just because it mutated). Codex round-3
# caught the missing exit-code assertion (the original `|| true` masked
# any regression where --reconcile dropped exit-1 along with the flip).
bash "$HC" --reconcile "$DRIFT_FIXTURE" >/dev/null 2>&1
reconcile_exit=$?

RECONCILED_SPEC=$(grep "^status:" "$DRIFT_FIXTURE/docs/specs/zeta.spec.md")
RECONCILED_REG=$(grep "zeta.spec.md" "$DRIFT_FIXTURE/docs/REGISTER.md")

if echo "$RECONCILED_SPEC" | grep -qE "status:[[:space:]]+stale" && echo "$RECONCILED_REG" | grep -qF "stale"; then
  pass "HC-5: Check 7 with --reconcile flips spec frontmatter AND REGISTER row to stale"
else
  fail_case "HC-5: Check 7 --reconcile did not flip both surfaces" "spec: $RECONCILED_SPEC | register: $RECONCILED_REG"
fi
if [ "$reconcile_exit" -eq 1 ]; then
  pass "HC-5: Check 7 --reconcile run still exits 1 (drift findings independent of mutation)"
else
  fail_case "HC-5: Check 7 --reconcile expected exit 1 (per HC-2 contract: --reconcile doesn't change exit-code semantics), got $reconcile_exit"
fi

# ── Summary ──────────────────────────────────────────────────────────

if [ $fail -eq 0 ]; then
  echo "All health-check contract assertions passed (HC-1..HC-7)."
  exit 0
else
  echo "health-check contract test FAILED" >&2
  exit 1
fi
