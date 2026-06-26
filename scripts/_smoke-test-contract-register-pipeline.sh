#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-register-pipeline.sh — Contract test for
# docs/contracts/register-pipeline.contract.md. Asserts the seven
# invariants RP-1..RP-7 from the contract's ## Test surface against
# scripts/generate-register.sh's current behaviour.
#
# Uses the fixture-project pattern: mktemp -d a project skeleton,
# populate docs/specs/ with edge-case specs, run generate-register.sh,
# inspect the produced REGISTER.md.
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
#
# Closes #259 (idempotency) and #128 (vocabulary-agnostic status summary)
# as non-recurrable by construction — any future regression fails this
# test in CI.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"

[ -f "$GEN" ] || { echo "FAIL: $GEN not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── Build fixture project ────────────────────────────────────────────

mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/src"

# Spec 1: canonical active
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

# Spec 2: extended enum (ready)
cat > "$FIXTURE/docs/specs/beta.spec.md" <<'INNER'
---
name: beta
status: ready
owner: architecture
owns:
  - src/beta.py
---

# beta
INNER

# Spec 3: extended enum (in-progress)
cat > "$FIXTURE/docs/specs/gamma.spec.md" <<'INNER'
---
name: gamma
status: in-progress
owner: architecture
owns:
  - src/gamma.py
---

# gamma
INNER

# Spec 4: empty owns (inline empty list form)
cat > "$FIXTURE/docs/specs/delta.spec.md" <<'INNER'
---
name: delta
status: draft
owner: architecture
owns: []
---

# delta
INNER

# Spec 5: arbitrary non-canonical status (proves RP-4 is vocabulary-agnostic,
# not just hard-coded for the documented examples 'ready' and 'in-progress').
# Per Codex review on PR #354: a regression that simply hard-codes
# {draft, active, stale, ready, in-progress} would pass without this spec.
cat > "$FIXTURE/docs/specs/epsilon.spec.md" <<'INNER'
---
name: epsilon
status: experimental
owner: architecture
owns:
  - src/epsilon.py
---

# epsilon
INNER

# Spec 6: no owns: block at all (the second form RP-6 covers). The fixture
# already tests `owns: []` via delta; this spec tests the no-field-at-all
# case so a regression that handles one but not the other gets caught.
# Per Codex review on PR #354.
cat > "$FIXTURE/docs/specs/zeta.spec.md" <<'INNER'
---
name: zeta
status: draft
owner: architecture
---

# zeta
INNER

echo "# owner: alpha"   > "$FIXTURE/src/alpha.py"
echo "# owner: beta"    > "$FIXTURE/src/beta.py"
echo "# owner: gamma"   > "$FIXTURE/src/gamma.py"
echo "# owner: epsilon" > "$FIXTURE/src/epsilon.py"

# Pre-existing REGISTER.md with preserved-section content for RP-5
cat > "$FIXTURE/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

## Spec Index

## Status Summary

## Unowned Code

This is hand-maintained content under Unowned Code that must survive regen.

## Dependency Resolution Order

This is hand-maintained content under Dependency Resolution Order that must survive regen.
INNER

# ── RP-1, RP-2, RP-3, RP-4, RP-5, RP-6: first regen + assertions ─────

GEN_OUT=$(bash "$GEN" "$FIXTURE" 2>&1)
gen_rc=$?
if [ $gen_rc -ne 0 ]; then
  fail_case "generate-register.sh exited non-zero on fixture (rc=$gen_rc)" "$GEN_OUT"
  exit 1
fi

REG="$FIXTURE/docs/REGISTER.md"

# RP-1: five required top-level sections present in fixed order.
# Uses grep -nxF (whole-line match) per Codex review on PR #354: -nF alone
# substring-matches demoted headings like '### Spec Index' or prose
# containing '## Spec Index', which would let a regression that emits only
# demoted-heading versions of the required sections silently pass this
# top-level-schema assertion.
required_sections=("## Definitions Index" "## Spec Index" "## Status Summary" "## Unowned Code" "## Dependency Resolution Order")
prev_line=0
rp1_ok=1
for section in "${required_sections[@]}"; do
  line=$(grep -nxF "$section" "$REG" | head -1 | cut -d: -f1 || true)
  if [ -z "$line" ]; then
    fail_case "RP-1: missing required section '$section'" "$(cat "$REG")"
    rp1_ok=0
  elif [ "$line" -le "$prev_line" ]; then
    fail_case "RP-1: section '$section' appears at line $line, not after previous section at line $prev_line"
    rp1_ok=0
  else
    prev_line=$line
  fi
done
[ $rp1_ok -eq 1 ] && pass "RP-1: five required sections in fixed order"

# RP-2: Spec Index column header is the 4-column schema
grep -qF "| Spec | Status | Owner | Owns (files/directories) |" "$REG" \
  && grep -qF "|------|--------|-------|--------------------------|" "$REG" \
  && pass "RP-2: Spec Index header is the 4-column schema" \
  || fail_case "RP-2: Spec Index column header missing or wrong" "$(grep -A1 '## Spec Index' "$REG")"

# RP-3: idempotency — second regen produces byte-identical output.
# Captures the second invocation's exit status before diffing, per Codex+Copilot
# review on PR #354: a second run that crashes but leaves the file unchanged
# would otherwise pass RP-3 spuriously (the diff returns equal). The rc check
# surfaces a regression as a real failure with the script's stderr output.
cp "$REG" "$FIXTURE/REGISTER.first.md"
GEN2_OUT=$(bash "$GEN" "$FIXTURE" 2>&1)
gen2_rc=$?
if [ $gen2_rc -ne 0 ]; then
  fail_case "RP-3: second generate-register.sh run exited non-zero (rc=$gen2_rc) — idempotency cannot be evaluated when the regenerator crashes" "$GEN2_OUT"
elif diff -q "$FIXTURE/REGISTER.first.md" "$REG" >/dev/null; then
  pass "RP-3: idempotency — back-to-back regens are byte-identical (both runs exit 0)"
else
  fail_case "RP-3: second regen produced different output" "$(diff -u "$FIXTURE/REGISTER.first.md" "$REG" | head -40)"
fi

# RP-4 (presence): every observed status label appears as a row.
# Includes 'experimental' — an arbitrary fixture status proving the generator
# really is vocabulary-agnostic. Per Codex review on PR #354: without an
# arbitrary label, a regression that simply enlarges the hard-coded set
# would still pass while silently dropping other observed labels.
for state in active ready in-progress draft experimental; do
  grep -qE "^\| $state \| [0-9]+ \|" "$REG" \
    && pass "RP-4 (presence): '$state' appears in Status Summary" \
    || fail_case "RP-4 (presence): status '$state' missing from Status Summary table" "$(sed -n '/## Status Summary/,/## /p' "$REG")"
done

# RP-4 (ordering): canonical states first in lifecycle order, then non-canonical alphabetical.
# Fixture has canonical {draft, active} (no stale) and non-canonical
# {experimental, in-progress, ready} (alphabetical).
# Expected emission order: draft, active, experimental, in-progress, ready.
line_draft=$(grep -nE "^\| draft \| [0-9]+ \|" "$REG" | head -1 | cut -d: -f1 || echo 0)
line_active=$(grep -nE "^\| active \| [0-9]+ \|" "$REG" | head -1 | cut -d: -f1 || echo 0)
line_experimental=$(grep -nE "^\| experimental \| [0-9]+ \|" "$REG" | head -1 | cut -d: -f1 || echo 0)
line_in_progress=$(grep -nE "^\| in-progress \| [0-9]+ \|" "$REG" | head -1 | cut -d: -f1 || echo 0)
line_ready=$(grep -nE "^\| ready \| [0-9]+ \|" "$REG" | head -1 | cut -d: -f1 || echo 0)

if [ "$line_draft" -gt 0 ] && [ "$line_active" -gt "$line_draft" ] \
   && [ "$line_experimental" -gt "$line_active" ] \
   && [ "$line_in_progress" -gt "$line_experimental" ] \
   && [ "$line_ready" -gt "$line_in_progress" ]; then
  pass "RP-4 (ordering): canonical (draft, active) before non-canonical (experimental, in-progress, ready) alphabetical"
else
  fail_case "RP-4 (ordering): Status Summary row order wrong (lines: draft=$line_draft, active=$line_active, experimental=$line_experimental, in-progress=$line_in_progress, ready=$line_ready); expected draft < active < experimental < in-progress < ready" \
            "$(sed -n '/## Status Summary/,/## /p' "$REG")"
fi

# RP-5: preserved-section content survives regen byte-for-byte.
# Per Codex+Copilot review on PR #354: the original substring-grep approach
# would have missed whitespace/newline/ordering changes within the preserved
# section. The contract claim is byte-for-byte preservation, so the test
# extracts each section's body (between its `## Header` line and the next
# top-level `## ` heading, with leading/trailing blank lines stripped) and
# compares against the exact text that the fixture put there.
#
# `generate-register.sh` normalizes trailing blank lines on preserved
# sections (per the script's `# Strip trailing blank lines so each
# regeneration doesn't accumulate them` discipline backing the
# idempotency invariant), so the comparison strips trailing blanks on
# both sides. Anything else — leading whitespace, internal text changes,
# duplicated content — must round-trip byte-for-byte.

extract_section_body() {
  # Args: file, "## Header text"
  # Output: the lines between the header and the next `## ` heading,
  # with leading and trailing blank lines stripped.
  awk -v hdr="$2" '
    $0==hdr { in_sec=1; next }
    /^## / { if (in_sec) in_sec=0 }
    in_sec { lines[++n]=$0 }
    END {
      start=1
      while (start<=n && lines[start]=="") start++
      end=n
      while (end>=start && lines[end]=="") end--
      for (i=start; i<=end; i++) print lines[i]
    }
  ' "$1"
}

EXPECTED_UNOWNED="This is hand-maintained content under Unowned Code that must survive regen."
ACTUAL_UNOWNED=$(extract_section_body "$REG" "## Unowned Code")
if [ "$ACTUAL_UNOWNED" = "$EXPECTED_UNOWNED" ]; then
  pass "RP-5: Unowned Code section body preserved byte-for-byte"
else
  fail_case "RP-5: Unowned Code byte-for-byte mismatch" "$(diff <(echo "$EXPECTED_UNOWNED") <(echo "$ACTUAL_UNOWNED") || true)"
fi

EXPECTED_DEPORDER="This is hand-maintained content under Dependency Resolution Order that must survive regen."
ACTUAL_DEPORDER=$(extract_section_body "$REG" "## Dependency Resolution Order")
if [ "$ACTUAL_DEPORDER" = "$EXPECTED_DEPORDER" ]; then
  pass "RP-5: Dependency Resolution Order section body preserved byte-for-byte"
else
  fail_case "RP-5: Dependency Resolution Order byte-for-byte mismatch" "$(diff <(echo "$EXPECTED_DEPORDER") <(echo "$ACTUAL_DEPORDER") || true)"
fi

# RP-6 (delta row — empty-list form): `owns: []` spec emits '—' in Owns column and didn't crash
grep -qE "^\| delta\.spec\.md \| draft \| architecture \| — \|" "$REG" \
  && pass "RP-6 (delta row, owns: []): empty-list-owns spec emits '—' in Owns column" \
  || fail_case "RP-6 (delta row, owns: []): delta (empty-list owns) row missing or wrong" "$(grep -F 'delta.spec.md' "$REG")"

# RP-6 (zeta row — no-owns-block form): spec with no `owns:` field at all
# also emits '—'. The contract covers BOTH the `owns: []` empty-list form
# (delta above) and the no-field-at-all form (zeta here) — a regression
# that handles one but not the other would otherwise slip through.
# Per Codex review on PR #354.
grep -qE "^\| zeta\.spec\.md \| draft \| architecture \| — \|" "$REG" \
  && pass "RP-6 (zeta row, no owns: block): no-owns-field spec emits '—' in Owns column" \
  || fail_case "RP-6 (zeta row, no owns: block): zeta (no owns: field) row missing or wrong" "$(grep -F 'zeta.spec.md' "$REG")"

# RP-6 (other-specs intact): alpha, beta, gamma, epsilon rows must still appear in Spec Index.
# The literal failure mode of #191 was the whole script crashing on the first
# empty-owns spec, dropping all subsequent specs from REGISTER.md. This
# assertion catches a re-occurrence.
for spec in alpha beta gamma epsilon; do
  grep -qE "^\| ${spec}\.spec\.md \| " "$REG" \
    && pass "RP-6 (other-specs): $spec.spec.md row present in Spec Index" \
    || fail_case "RP-6 (other-specs): $spec.spec.md row missing — empty-owns spec may be dropping subsequent specs" \
                 "$(sed -n '/## Spec Index/,/## /p' "$REG")"
done

# ── RP-7: dry-run no-write ──────────────────────────────────────────

cp "$REG" "$FIXTURE/REGISTER.before-dryrun.md"
DRYRUN1_OUT=$(bash "$GEN" "$FIXTURE" --dry-run 2>&1 >/dev/null)
dry_rc=$?
if [ $dry_rc -ne 0 ]; then
  fail_case "RP-7: --dry-run exited non-zero (rc=$dry_rc)" "$DRYRUN1_OUT"
else
  if diff -q "$FIXTURE/REGISTER.before-dryrun.md" "$REG" >/dev/null; then
    pass "RP-7: --dry-run does not modify REGISTER.md on disk"
  else
    fail_case "RP-7: --dry-run modified REGISTER.md" "$(diff -u "$FIXTURE/REGISTER.before-dryrun.md" "$REG" | head -20)"
  fi
fi

# Confirm dry-run actually printed something to stdout
DRYRUN_OUT=$(bash "$GEN" "$FIXTURE" --dry-run 2>/dev/null)
dry_rc=$?
if [ $dry_rc -ne 0 ]; then
  fail_case "RP-7: --dry-run exited non-zero on stdout capture (rc=$dry_rc)"
elif echo "$DRYRUN_OUT" | grep -qF "## Spec Index"; then
  pass "RP-7: --dry-run prints generated content to stdout"
else
  fail_case "RP-7: --dry-run did not print Spec Index to stdout"
fi

# ── Summary ──────────────────────────────────────────────────────────

if [ $fail -eq 0 ]; then
  echo "All register-pipeline contract assertions passed (RP-1..RP-7)."
  exit 0
else
  echo "register-pipeline contract test FAILED" >&2
  exit 1
fi
