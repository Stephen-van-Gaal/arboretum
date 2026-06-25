#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# _smoke-test-check7-read-only.sh — Check 7 read-only-by-default contract.
#
# Asserts two behaviours introduced by the --reconcile flag:
#
#   1. Without --reconcile: drift is REPORTED but no files are mutated.
#      (Spec status and REGISTER.md must be unchanged after the run.)
#
#   2. With --reconcile: drift IS written — spec flipped to stale and
#      REGISTER.md updated. (The pre-existing mutation behaviour, now
#      gate-controlled.)
#
# Usage: bash scripts/_smoke-test-check7-read-only.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"
CHECK="$SCRIPT_DIR/health-check.sh"

[ -f "$GEN" ]   || { echo "FAIL: $GEN not found"   >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Build fixture with a DRIFT condition ─────────────────────────────
#
# Commit A: spec (status: active, owns: src/foo.py) + scaffolding + REGISTER.md
# Commit B: modified src/foo.py
#
# Result: src/foo.py's last commit (B) is after the spec's last commit (A)
# → Check 7 detects drift.

mkdir -p "$FIXTURE/docs/specs" \
         "$FIXTURE/docs/definitions" \
         "$FIXTURE/src" \
         "$FIXTURE/workflows"

echo "# fixture" > "$FIXTURE/workflows/README.md"
echo "# fixture" > "$FIXTURE/CLAUDE.md"
echo "# fixture" > "$FIXTURE/docs/ARCHITECTURE.md"
echo "# fixture" > "$FIXTURE/contracts.yaml"

cat > "$FIXTURE/docs/specs/foo.spec.md" <<'EOF'
---
name: foo
status: active
owner: alice
owns:
  - src/foo.py
---

# foo

Fixture spec.
EOF

# Real (non-comment) content so Commit B is a behaviour change — Check 7
# is content-aware (#238) and would treat a comment-only edit as benign.
printf '# owner: foo\ndef foo():\n    return 1\n' > "$FIXTURE/src/foo.py"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null

# Generate REGISTER.md before the first commit so it reflects 'active'
bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh failed (pre-drift commit)"

# Commit A: everything including REGISTER.md
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture init"

# Commit B: behaviour change to owned file AFTER the spec → introduces drift
printf '# owner: foo\ndef foo():\n    return 2\n' > "$FIXTURE/src/foo.py"
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add src/foo.py >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "update foo"

# ── Snapshot pre-run state ────────────────────────────────────────────

SPEC_STATUS_BEFORE=$(grep '^status:' "$FIXTURE/docs/specs/foo.spec.md")
REGISTER_ROW_BEFORE=$(grep 'foo\.spec\.md' "$FIXTURE/docs/REGISTER.md")

# ── Test 1: no --reconcile → drift reported, NO mutation ─────────────

set +e
OUT1=$(bash "$CHECK" "$FIXTURE" 2>&1)
RC1=$?
set -e

# Drift should be detected → non-zero exit
[ "$RC1" -ne 0 ] \
  || fail "health-check.sh exit 0 despite drift — expected non-zero" "$OUT1"

# Output must mention drift
echo "$OUT1" | grep -qi 'drift' \
  || fail "health-check.sh output did not mention drift" "$OUT1"

# Spec status must be UNCHANGED (still 'active')
SPEC_STATUS_AFTER=$(grep '^status:' "$FIXTURE/docs/specs/foo.spec.md")
[ "$SPEC_STATUS_AFTER" = "$SPEC_STATUS_BEFORE" ] \
  || fail "health-check.sh mutated spec status without --reconcile" \
          "before: $SPEC_STATUS_BEFORE | after: $SPEC_STATUS_AFTER"

# REGISTER.md status row must be UNCHANGED
REGISTER_ROW_AFTER=$(grep 'foo\.spec\.md' "$FIXTURE/docs/REGISTER.md")
[ "$REGISTER_ROW_AFTER" = "$REGISTER_ROW_BEFORE" ] \
  || fail "health-check.sh mutated REGISTER.md without --reconcile" \
          "before: $REGISTER_ROW_BEFORE | after: $REGISTER_ROW_AFTER"

echo "PASS (test 1): drift reported, no mutation without --reconcile"

# ── Test 2: --reconcile --all → drift reported AND mutation applied ───
#
# This test pins the *mutation mechanics* (atomic active→stale in both the spec
# frontmatter and the REGISTER row), which are scope-independent. The fixture is
# a single commit-chain with no feature branch, so HEAD is the integration base
# (merge-base == HEAD) and the #750 default-scoped --reconcile correctly flips
# nothing. --all opts into the repo-wide flip to exercise the mutation here;
# branch-scoping itself is pinned by _smoke-test-check7-branch-scope.sh.

set +e
OUT2=$(bash "$CHECK" --reconcile --all "$FIXTURE" 2>&1)
RC2=$?
set -e

# Drift should still be detected → non-zero exit
[ "$RC2" -ne 0 ] \
  || fail "health-check.sh --reconcile --all exit 0 despite drift — expected non-zero" "$OUT2"

# Spec status must be flipped to stale
SPEC_STATUS_RECONCILED=$(grep '^status:' "$FIXTURE/docs/specs/foo.spec.md")
[ "$SPEC_STATUS_RECONCILED" = "status: stale" ] \
  || fail "health-check.sh --reconcile --all did not flip spec status to stale" \
          "got: $SPEC_STATUS_RECONCILED"

# REGISTER.md must reflect stale
REGISTER_ROW_RECONCILED=$(grep 'foo\.spec\.md' "$FIXTURE/docs/REGISTER.md")
echo "$REGISTER_ROW_RECONCILED" | grep -q 'stale' \
  || fail "health-check.sh --reconcile --all did not update REGISTER.md to stale" \
          "got: $REGISTER_ROW_RECONCILED"

echo "PASS (test 2): --reconcile --all flips spec and REGISTER to stale"
