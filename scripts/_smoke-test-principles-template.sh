#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-principles-template.sh — Verify PRINCIPLES.md ships
# from docs/templates/ and lands at the consumer project's repo root.
#
# Issue stvangaal/arboretum#13: cross-refs to docs/ARCHITECTURE.md §N
# anchors broke when projects adopted the shipped PRINCIPLES.md
# verbatim (their ARCHITECTURE doc didn't have those anchors). The
# fix relocates PRINCIPLES.md to docs/templates/ to signal it's
# starting material, with a header note guiding adopters.
#
# Usage: bash scripts/_smoke-test-principles-template.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-project.sh"

[ -f "$BOOTSTRAP" ] || { echo "FAIL: $BOOTSTRAP not found" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Plugin-side invariant: template exists, root copy doesn't ────────

[ -f "$PROJECT_ROOT/docs/templates/PRINCIPLES.md" ] \
  || fail "docs/templates/PRINCIPLES.md not found in plugin tree" \
          "expected the template-shaped principles file at the new location"

if [ -f "$PROJECT_ROOT/PRINCIPLES.md" ]; then
  fail "PRINCIPLES.md still exists at plugin root — should live only under docs/templates/" \
       "$(ls -la "$PROJECT_ROOT/PRINCIPLES.md")"
fi

# Adopter-facing header note must mention that cross-refs need
# editing. Both halves of the note are part of the contract.
head -20 "$PROJECT_ROOT/docs/templates/PRINCIPLES.md" \
  | grep -q "adopter-editable template" \
  || fail "template missing 'adopter-editable template' header note" \
          "$(head -20 "$PROJECT_ROOT/docs/templates/PRINCIPLES.md")"

head -20 "$PROJECT_ROOT/docs/templates/PRINCIPLES.md" \
  | grep -q "anchors exist in \*arboretum's\*" \
  || fail "template missing cross-ref warning in header note" \
          "$(head -20 "$PROJECT_ROOT/docs/templates/PRINCIPLES.md")"

# ── End-to-end: bootstrap copies template to consumer's project root ─

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# bootstrap-project.sh must complete cleanly (exit 0): #420 made the
# template-copy loop directory-aware, so the prior cp-on-subdirectory abort
# no longer swallows the exit status. Bootstrap output is captured (not
# suppressed) so failure diagnostics include the actual error if the
# relocation broke something upstream.
BOOTSTRAP_LOG=$(mktemp)
trap 'rm -rf "$FIXTURE" "$BOOTSTRAP_LOG"' EXIT
bash "$BOOTSTRAP" "$FIXTURE" test-project >"$BOOTSTRAP_LOG" 2>&1 \
  || fail "bootstrap-project.sh exited non-zero" "$(cat "$BOOTSTRAP_LOG")"

[ -f "$FIXTURE/PRINCIPLES.md" ] \
  || fail "bootstrap did not create PRINCIPLES.md in consumer project root" \
          "$(cat "$BOOTSTRAP_LOG")"

# Adopter-facing copy must carry the header note forward — that's the
# whole point of the relocation. If bootstrap copied from the wrong
# source, the header would be missing and the failure would be silent.
head -20 "$FIXTURE/PRINCIPLES.md" | grep -q "adopter-editable template" \
  || fail "consumer project's PRINCIPLES.md missing adopter header note" \
          "$(head -20 "$FIXTURE/PRINCIPLES.md")"

# Sanity: principle 1 still present (bootstrap didn't truncate).
grep -q "Decide before you build, describe after you ship" "$FIXTURE/PRINCIPLES.md" \
  || fail "consumer project's PRINCIPLES.md missing principle 1 — bootstrap may have copied a stub" \
          "$(cat "$FIXTURE/PRINCIPLES.md")"

echo "PASS: principles relocation — template at docs/templates/, bootstrap copies adopter copy to root with header note intact"
