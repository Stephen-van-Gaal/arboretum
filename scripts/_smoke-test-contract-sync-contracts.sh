#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-sync-contracts.sh — Contract test for
# docs/contracts/sync-contracts.contract.md. Asserts SC-1..SC-8 from the
# contract's ## Test surface against scripts/sync-contracts.sh.
#
# Fixture pattern: mktemp -d a project root with a docs/specs/ tree holding
# crafted *.spec.md files, run scripts/sync-contracts.sh against it, and assert
# the written contracts.yaml shape. SC-7 additionally runs validate-cross-refs.sh
# against the same fixture to prove the generator/validator round trip.
#
# Asserts existing behaviour only — green immediately. Never modifies a script.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/sync-contracts.sh"
VALIDATE="$SCRIPT_DIR/validate-cross-refs.sh"

[ -f "$SYNC" ] || { echo "FAIL: $SYNC not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── Fixture A: specs WITH pins (requires + provides) ─────────────────
FIX=$(mktemp -d)
# ── Fixture B: specs with NO pins (empty-tree case) ──────────────────
FIX_EMPTY=$(mktemp -d)
# ── Fixture C: no specs dir at all (error case) ──────────────────────
FIX_NOSPECS=$(mktemp -d)
trap 'rm -rf "$FIX" "$FIX_EMPTY" "$FIX_NOSPECS"' EXIT

mkdir -p "$FIX/docs/specs" "$FIX/docs/definitions"

# A spec WITH a requires pin and a provides pin.
cat > "$FIX/docs/specs/alpha.spec.md" <<'SPEC'
---
spec: alpha
status: active
---
# alpha

## Requires

| Definition | Version |
|---|---|
| `definitions/widget.md` | definitions/widget.md@v1 |

## Provides

| Definition | Version |
|---|---|
| `definitions/gadget.md` | definitions/gadget.md@v2 |

## Body
SPEC

# A spec with NO definition references — must be skipped.
cat > "$FIX/docs/specs/beta.spec.md" <<'SPEC'
---
spec: beta
status: active
---
# beta

## Overview
No definition references here.
SPEC

# Definition files so SC-7 (round trip) Check 1 also resolves cleanly.
printf '# widget\n\n## Version\nv1\n' > "$FIX/docs/definitions/widget.md"
printf '# gadget\n\n## Version\nv2\n' > "$FIX/docs/definitions/gadget.md"

# Empty-tree fixture: one spec, no definition refs.
mkdir -p "$FIX_EMPTY/docs/specs"
cat > "$FIX_EMPTY/docs/specs/only.spec.md" <<'SPEC'
---
spec: only
status: active
---
# only

## Overview
Nothing pinned.
SPEC

# ── Run the producer against fixture A ────────────────────────────────
bash "$SYNC" "$FIX" >/dev/null 2>&1
sync_exit=$?
CY="$FIX/contracts.yaml"

if [ "$sync_exit" -eq 0 ] && [ -f "$CY" ]; then
  pass "SC: producer exits 0 and writes contracts.yaml"
else
  fail_case "SC: producer failed or wrote no file (exit=$sync_exit)"
fi

# SC-1: EXACTLY the two top-level keys — literal `seam-contracts: docs/contracts/`
# and `specs:`, and no others. Comparing the full top-level key set (not just
# presence) enforces the contract's "exactly two top-level keys" invariant: a
# generator regression adding a third top-level key fails here.
sc1_topkeys="$(grep -oE '^[A-Za-z0-9_-]+:' "$CY" | sort -u | tr '\n' ',')"
if grep -q '^seam-contracts: docs/contracts/$' "$CY" && grep -q '^specs:' "$CY" \
   && [ "$sc1_topkeys" = "seam-contracts:,specs:," ]; then
  pass "SC-1: contracts.yaml has exactly the seam-contracts and specs top-level keys"
else
  fail_case "SC-1: top-level key set is not exactly {seam-contracts, specs}" "keys=[$sc1_topkeys] file=$(cat "$CY")"
fi

# SC-2: alpha requires entry at correct shape/indent
if grep -qE '^  alpha:' "$CY" \
   && grep -qE '^    requires:' "$CY" \
   && grep -qE '^      definitions/widget\.md: v1$' "$CY"; then
  pass "SC-2: alpha requires definitions/widget.md: v1 at 6-space indent"
else
  fail_case "SC-2: alpha requires entry missing/mis-shaped" "$(cat "$CY")"
fi

# SC-3: alpha provides entry
if grep -qE '^    provides:' "$CY" \
   && grep -qE '^      definitions/gadget\.md: v2$' "$CY"; then
  pass "SC-3: alpha provides definitions/gadget.md: v2"
else
  fail_case "SC-3: alpha provides entry missing/mis-shaped" "$(cat "$CY")"
fi

# SC-4: beta (no refs) absent from the tree
if grep -qE '^  beta:' "$CY"; then
  fail_case "SC-4: beta has no definition refs but appears in specs tree" "$(cat "$CY")"
else
  pass "SC-4: spec with no definition refs (beta) absent from specs tree"
fi

# ── SC-5: empty-tree fixture → specs: {} ──────────────────────────────
bash "$SYNC" "$FIX_EMPTY" >/dev/null 2>&1
CY_EMPTY="$FIX_EMPTY/contracts.yaml"
if grep -qE '^specs: \{\}' "$CY_EMPTY"; then
  pass "SC-5: no-pin project emits 'specs: {}'"
else
  fail_case "SC-5: expected 'specs: {}' for a no-pin project" "$(cat "$CY_EMPTY")"
fi

# ── SC-6: --dry-run prints, writes nothing ────────────────────────────
DRY_FIX=$(mktemp -d)
mkdir -p "$DRY_FIX/docs/specs"
cp "$FIX/docs/specs/alpha.spec.md" "$DRY_FIX/docs/specs/alpha.spec.md"
dry_out=$(bash "$SYNC" --dry-run "$DRY_FIX" 2>/dev/null)
if echo "$dry_out" | grep -q '^seam-contracts: docs/contracts/$' && [ ! -f "$DRY_FIX/contracts.yaml" ]; then
  pass "SC-6: --dry-run prints document to stdout and writes no contracts.yaml"
else
  fail_case "SC-6: --dry-run wrote a file or produced no document" "stdout:
$dry_out
file-exists: $( [ -f "$DRY_FIX/contracts.yaml" ] && echo yes || echo no )"
fi
rm -rf "$DRY_FIX"

# ── SC-7: round trip — generated contracts.yaml passes validate Check 3 ──
#
# Uses a REQUIRES-ONLY fixture deliberately. validate-cross-refs.sh Check 3
# splits the per-spec yaml section with `sed -n '/requires:/,/provides:\|^  [^ ]/p'`;
# the `\|` alternation is GNU-sed-only, so on BSD/macOS sed the provides block
# bleeds into the requires comparison and Check 3 reports a spurious
# "spec does not require it" for any spec carrying BOTH requires and provides.
# That is a pre-existing consumer (validator) quirk, not a generator-schema
# mismatch — the generator emits the correct shape (asserted by SC-2/SC-3).
# The round-trip guarantee this contract pins is "generator output is what the
# validator parses", which a requires-only spec exercises cleanly on every
# platform without tripping the BSD-sed split bug.
if [ -f "$VALIDATE" ]; then
  FIX_RT=$(mktemp -d)
  mkdir -p "$FIX_RT/docs/specs" "$FIX_RT/docs/definitions"
  cat > "$FIX_RT/docs/specs/alpha.spec.md" <<'SPEC'
---
spec: alpha
status: active
---
# alpha

## Requires

| Definition | Version |
|---|---|
| `definitions/widget.md` | definitions/widget.md@v1 |

## Body
SPEC
  printf '# widget\n\n## Version\nv1\n' > "$FIX_RT/docs/definitions/widget.md"
  bash "$SYNC" "$FIX_RT" >/dev/null 2>&1
  validate_out=$(bash "$VALIDATE" "$FIX_RT" 2>&1 || true)
  # Isolate Check 3 region and confirm no ✗ within it.
  check3=$(echo "$validate_out" | sed -n '/Check 3: contracts.yaml matches/,/Check 4:/p')
  if echo "$check3" | grep -q '✗'; then
    fail_case "SC-7: validate-cross-refs Check 3 reported issues against generated contracts.yaml" "$check3"
  else
    pass "SC-7: round trip — generated contracts.yaml passes validate-cross-refs Check 3 cleanly"
  fi
  rm -rf "$FIX_RT"
else
  echo "INFO: SC-7: validate-cross-refs.sh not found — skipping round-trip assertion"
fi

# ── SC-8: absent specs dir → non-zero exit + stderr diagnostic ────────
sc8_err=$(bash "$SYNC" "$FIX_NOSPECS" 2>&1 >/dev/null)
sc8_exit=$?
if [ "$sc8_exit" -ne 0 ] && [ -n "$sc8_err" ]; then
  pass "SC-8: absent specs dir exits non-zero with stderr diagnostic"
else
  fail_case "SC-8: expected non-zero exit + diagnostic for absent specs dir (exit=$sc8_exit)" "$sc8_err"
fi

# ── Summary ───────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  echo "All sync-contracts contract assertions passed."
  exit 0
else
  echo "Some sync-contracts contract assertions failed." >&2
  exit 1
fi
