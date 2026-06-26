#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-extended-enum.sh — Verify health-check tolerates richer
# status vocabularies (draft/ready/in-progress/implemented) without
# per-spec warnings, and that Check 7 reports an explicit no-op
# rather than a silent skip.
#
# Issue stvangaal/arboretum#12: plugin's health-check.sh hard-coded
# draft/active/stale. Projects using a four-state enum had two bad
# options: (a) flood of "unknown status" warnings, one per spec, or
# (b) silent no-op on auto-flip with no acknowledgement.
#
# Decision (Option A): graceful no-op. Check 6 emits a single info
# line acknowledging the extended enum; Check 7 surfaces the no-op
# explicitly when no spec is at canonical `active`.
#
# Usage: bash scripts/_smoke-test-extended-enum.sh
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

# ── Build fixture project with four-state extended enum ──────────────

mkdir -p "$FIXTURE/workflows" \
         "$FIXTURE/docs/specs" \
         "$FIXTURE/docs/definitions" \
         "$FIXTURE/src" \
         "$FIXTURE/tests"

echo "# fixture" > "$FIXTURE/workflows/README.md"
echo "# fixture" > "$FIXTURE/CLAUDE.md"
echo "# fixture" > "$FIXTURE/docs/ARCHITECTURE.md"
echo "# fixture" > "$FIXTURE/contracts.yaml"

# Three specs spanning the extended enum. None at canonical `active`,
# so Check 7 auto-flip must be a no-op.
cat > "$FIXTURE/docs/specs/alpha.spec.md" <<'EOF'
---
name: alpha
status: ready
owner: alice
owns:
  - src/alpha.py
---

# alpha
EOF

cat > "$FIXTURE/docs/specs/beta.spec.md" <<'EOF'
---
name: beta
status: in-progress
owner: bob
owns:
  - src/beta.py
---

# beta
EOF

cat > "$FIXTURE/docs/specs/gamma.spec.md" <<'EOF'
---
name: gamma
status: implemented
owner: carol
owns:
  - src/gamma.py
---

# gamma
EOF

echo "# owner: alpha" > "$FIXTURE/src/alpha.py"
echo "# owner: beta"  > "$FIXTURE/src/beta.py"
echo "# owner: gamma" > "$FIXTURE/src/gamma.py"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture init"

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero"

# ── Run health-check and inspect Check 6/7 behaviour ─────────────────

set +e
HEALTH_OUT=$(bash "$CHECK" "$FIXTURE" 2>&1)
HEALTH_RC=$?
set -e

# Exit code is part of the contract: an extended-enum fixture with no
# real drift must exit 0. If a regression starts returning non-zero
# (e.g. Check 6 reverts to per-spec warnings or Check 7 mis-mutates),
# this assertion catches it before the more granular checks below.
[ "$HEALTH_RC" -eq 0 ] \
  || fail "health-check exited $HEALTH_RC on a clean extended-enum fixture, expected 0" "$HEALTH_OUT"

# Filter to the Check 6 section so substring-grep assertions can't be
# satisfied by output elsewhere (e.g. a spec name containing "ready"
# leaking through Check 2). The sed prints lines between the Check 6
# header and the next ━━━ header.
CHECK6_BLOCK=$(echo "$HEALTH_OUT" | sed -n '/Check 6:/,/━━━ Check [0-9]/p')

# Check 6 must NOT produce per-spec "unknown status" warnings — the
# regression mode this issue fixes. Old behaviour emitted one warn
# per spec; we expect exactly zero.
echo "$CHECK6_BLOCK" | grep -qF "unknown status" \
  && fail "Check 6 emitted 'unknown status' warning(s) for extended-enum project" "$HEALTH_OUT"

# Check 6 must emit a single info line acknowledging the extended enum
# AND naming the distinct states observed. Adopters seeing their own
# vocabulary is part of the contract — they know the plugin saw them
# rather than silently ignoring them. grep -F prevents regex
# interpretation of literal strings.
echo "$CHECK6_BLOCK" | grep -qF "Project uses extended status enum" \
  || fail "Check 6 missing extended-enum info line" "$HEALTH_OUT"

for state in ready in-progress implemented; do
  echo "$CHECK6_BLOCK" | grep -qF "$state" \
    || fail "Check 6 info line did not list observed state '$state'" "$HEALTH_OUT"
done

# Check 7 must report the no-op explicitly (cross-referencing Check 6),
# not silently skip. "No active specs to check" was the old wording;
# the new wording is more informative.
echo "$HEALTH_OUT" | grep -qF "drift auto-flip is a no-op" \
  || fail "Check 7 did not explicitly surface the no-op for extended-enum project" "$HEALTH_OUT"

# Mutation check: no spec frontmatter should have been flipped, and the
# REGISTER.md status column should still show the extended-enum values.
for spec_name in alpha beta gamma; do
  if grep -qF 'status: stale' "$FIXTURE/docs/specs/${spec_name}.spec.md"; then
    fail "spec $spec_name was incorrectly flipped to stale (mutation on extended-enum project)" \
         "$(cat "$FIXTURE/docs/specs/${spec_name}.spec.md")"
  fi
done

# REGISTER must still carry the extended-enum statuses, untouched.
# grep -F treats the patterns as literal strings (no regex metacharacter
# interpretation of `.` in `.spec.md`).
grep -qF '| alpha.spec.md | ready '       "$FIXTURE/docs/REGISTER.md" \
  || fail "REGISTER lost 'ready' status for alpha" "$(cat "$FIXTURE/docs/REGISTER.md")"
grep -qF '| beta.spec.md | in-progress '  "$FIXTURE/docs/REGISTER.md" \
  || fail "REGISTER lost 'in-progress' status for beta" "$(cat "$FIXTURE/docs/REGISTER.md")"
grep -qF '| gamma.spec.md | implemented ' "$FIXTURE/docs/REGISTER.md" \
  || fail "REGISTER lost 'implemented' status for gamma" "$(cat "$FIXTURE/docs/REGISTER.md")"

echo "PASS: extended-enum tolerance — single info line, no false warnings, no false mutations"
