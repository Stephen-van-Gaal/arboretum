#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-check7-keep-active.sh — Check 7 --reconcile --keep-active (#666, #870).
#
# Role separation: when /consolidate has reconciled a spec clean, the conductor
# passes it in --keep-active and health-check SKIPS the stale-flip for it. Drift
# specs NOT in the list still flip. This is the testable guard that impl-detail
# hardening stays active (#870): the same drifted spec stays active WITH the
# exemption and flips stale WITHOUT it (the control), proving the exemption is
# what protects it.
#
# Fixture: spec alpha (active, owns src/alpha.py) drifted in scope on a feature
# branch. --keep-active is report-side only (no write), so the two sub-cases run
# sequentially on one fixture: exempted run stays active, then the unexempted
# control run flips stale.
#
# Usage: bash scripts/_smoke-test-check7-keep-active.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail
[ -z "${BASH_VERSION:-}" ] && { echo "Run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"
CHECK="$SCRIPT_DIR/health-check.sh"
[ -f "$GEN" ]   || { echo "FAIL: $GEN not found"   >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }

FIXTURE=$(mktemp -d); trap 'rm -rf "$FIXTURE"' EXIT
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; exit 1; }
G() { git -C "$FIXTURE" -c user.email=t@t -c user.name=t "$@"; }
status_of() { grep '^status:' "$FIXTURE/docs/specs/alpha.spec.md"; }

mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/docs/definitions" "$FIXTURE/src" "$FIXTURE/workflows"
for f in workflows/README.md CLAUDE.md docs/ARCHITECTURE.md contracts.yaml; do echo "# fixture" > "$FIXTURE/$f"; done

cat > "$FIXTURE/docs/specs/alpha.spec.md" <<'EOF'
---
name: alpha
status: active
owner: alice
owns:
  - src/alpha.py
---

# alpha
Fixture spec.
EOF
printf '# owner: alpha\ndef alpha():\n    return 1\n' > "$FIXTURE/src/alpha.py"

G init -q
G branch -M main
G add . >/dev/null
bash "$GEN" "$FIXTURE" >/dev/null || fail "generate-register.sh failed"
G add . >/dev/null
G commit -q -m "fixture init (alpha active, no drift)"

# Feature branch: drift the owned file in scope (impl-detail hardening analogue).
G checkout -q -b feat/keep-active-test
printf '# owner: alpha\ndef alpha():\n    return 2\n' > "$FIXTURE/src/alpha.py"
G add src/alpha.py >/dev/null
G commit -q -m "feature: drift alpha in scope"

# ── Test 1: --keep-active protects the reconciled spec (#870) ─────────
# Guard against a false positive: an UNKNOWN --keep-active flag would exit 64
# before reconciling, leaving the spec active for the wrong reason. Assert the
# flag was actually accepted (no usage error) before trusting the active status.
set +e; OUT=$(bash "$CHECK" --reconcile --keep-active alpha.spec.md "$FIXTURE" 2>&1); RC=$?; set -e
echo "$OUT" | grep -qi 'unknown flag' \
  && fail "--keep-active was rejected as an unknown flag (test would false-positive)" "$OUT"
[ "$RC" -ne 64 ] \
  || fail "--keep-active triggered a usage error (exit 64) instead of being parsed" "$OUT"
[ "$(status_of)" = "status: active" ] \
  || fail "keep-active did NOT protect spec from stale-flip (#870 regression)" "$OUT"
grep -q '^| alpha.spec.md | active ' "$FIXTURE/docs/REGISTER.md" \
  || fail "keep-active did NOT protect spec's REGISTER row" "$(grep '\.spec\.md' "$FIXTURE/docs/REGISTER.md")"
echo "PASS (test 1): keep-active keeps a reconciled drifted spec active (both surfaces)"

# ── Test 2: control — WITHOUT keep-active the same drift flips stale ───
set +e; OUT=$(bash "$CHECK" --reconcile "$FIXTURE" 2>&1); set -e
[ "$(status_of)" = "status: stale" ] \
  || fail "control: unexempted drift spec should have flipped stale (proves keep-active is what protected it)" "$OUT"
grep -q '^| alpha.spec.md | stale ' "$FIXTURE/docs/REGISTER.md" \
  || fail "control: unexempted spec's REGISTER row should be stale" "$(grep '\.spec\.md' "$FIXTURE/docs/REGISTER.md")"
echo "PASS (test 2): control — unexempted drift flips stale"

# ── Test 3: whitespace-padded list entries still exempt (#870 LLM-input) ──
# The conductor is LLM-prose-driven; the natural form is "a.spec.md, b.spec.md"
# with a space after the comma. A non-trimming match would silently fail to
# exempt the padded entry and re-introduce the stale-flip. Reset to active first
# (control flipped it stale), then exempt with surrounding whitespace.
G checkout HEAD -- docs/specs/alpha.spec.md docs/REGISTER.md
[ "$(status_of)" = "status: active" ] || fail "fixture reset did not restore active"
set +e; OUT3=$(bash "$CHECK" --reconcile --keep-active " alpha.spec.md " "$FIXTURE" 2>&1); set -e
[ "$(status_of)" = "status: active" ] \
  || fail "keep-active with surrounding whitespace did NOT exempt the spec (#870 LLM-input regression)" "$OUT3"
echo "PASS (test 3): whitespace-padded keep-active entry still exempts"

echo "ALL PASS"
