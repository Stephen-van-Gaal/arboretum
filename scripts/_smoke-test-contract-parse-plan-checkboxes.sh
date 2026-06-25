#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-contract-parse-plan-checkboxes.sh — Contract test for
# docs/contracts/parse-plan-checkboxes.contract.md. Asserts PPC-1..PPC-7
# against scripts/parse-plan-checkboxes.sh using mktemp plan fixtures.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/parse-plan-checkboxes.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

PLAN="$FIX/plan.md"

# PPC-1 — 2 open, 1 plain checked, 1 skipped → open=2 total=4 skipped=1
cat > "$PLAN" <<'EOF'
# Plan
- [ ] task one
- [ ] task two
- [x] task three done
- [x] (skipped: not needed) task four
EOF
out=$(bash "$PROBE" "$PLAN" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "open=2 total=4 skipped=1" ] && pass PPC-1 || fail_case PPC-1 "rc=$rc out=$out"

# PPC-2 — all checked, none skipped
cat > "$PLAN" <<'EOF'
- [x] a
- [x] b
- [x] c
EOF
out=$(bash "$PROBE" "$PLAN" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "open=0 total=3 skipped=0" ] && pass PPC-2 || fail_case PPC-2 "rc=$rc out=$out"

# PPC-3 — empty plan (no checkboxes)
printf '# A plan with prose only\nNothing to do.\n' > "$PLAN"
out=$(bash "$PROBE" "$PLAN" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "open=0 total=0 skipped=0" ] && pass PPC-3 || fail_case PPC-3 "rc=$rc out=$out"

# PPC-4 — indented (nested) open checkbox is counted
cat > "$PLAN" <<'EOF'
- [ ] parent
    - [ ] nested child
EOF
out=$(bash "$PROBE" "$PLAN" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "open=2 total=2 skipped=0" ] && pass PPC-4 || fail_case PPC-4 "rc=$rc out=$out"

# PPC-5 — skipped counts in total+skipped, not in open
cat > "$PLAN" <<'EOF'
- [x] (skipped: out of scope) only one line
EOF
out=$(bash "$PROBE" "$PLAN" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "open=0 total=1 skipped=1" ] && pass PPC-5 || fail_case PPC-5 "rc=$rc out=$out"

# PPC-6 — missing file → exit 1
out=$(bash "$PROBE" "$FIX/nope.md" 2>"$FIX/.err"); rc=$?
[ "$rc" = 1 ] && [ -s "$FIX/.err" ] && pass PPC-6 || fail_case PPC-6 "rc=$rc out=$out"

# PPC-7 — read-only
cat > "$PLAN" <<'EOF'
- [ ] x
- [x] y
EOF
before=$(shasum "$PLAN" | cut -d' ' -f1); bash "$PROBE" "$PLAN" >/dev/null 2>&1
after=$(shasum "$PLAN" | cut -d' ' -f1)
[ "$before" = "$after" ] && pass PPC-7 || fail_case PPC-7 "plan mutated"

[ "$fail" = 0 ] && echo "parse-plan-checkboxes contract: ALL PASS" || exit 1
