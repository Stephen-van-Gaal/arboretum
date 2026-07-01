#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# detect-design-doc-pr.sh — print "--design-doc" when the current branch is a
# design-doc PR, else print nothing. Single source of the design-doc PR class
# (#935), so /pr and /land scope reviewer requests identically (no drift).
#
# A branch is a design-doc PR when BOTH hold:
#   1. its design spec resolves by the §5.5 branch-slug convention and is
#      `kind: shaping`, and
#   2. the branch diff against <base-ref> classifies as `docs-config`
#      (classify-pr-change.sh — the load-bearing gate; a code/skill-bearing diff
#      is never a design-doc PR).
#
# Usage: detect-design-doc-pr.sh <base-ref>
# Output: `--design-doc\n` or nothing. Always exits 0 (callers interpolate the
# result straight into a request-review.sh call; an unresolved branch degrades
# to the empty string = normal review).
set -uo pipefail

# An absent or empty base ref degrades to empty (normal review), never a hard
# fail — both callers interpolate stdout straight into request-review.sh, and the
# contract guarantees exit 0 always.
BASE="${1:-}"
[ -n "$BASE" ] || exit 0
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$PWD")"
cd "$ROOT" 2>/dev/null || exit 0

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0
SLUG="${BRANCH#*/}"   # strip prefix through the first '/'
# Candidates (§5.5 convention): the slug, the slug with a trailing -build
# stripped, and — for this repo's issue-prefixed branches (feat/<issue>-<topic>)
# — the slug with a leading "<issue>-" stripped, so feat/935-codex-design-review
# resolves 2026-06-28-codex-design-review-design.md.
CANDS="$SLUG ${SLUG%-build}"
case "$SLUG" in
  [0-9]*-*) NOISSUE="${SLUG#*-}"; CANDS="$CANDS $NOISSUE ${NOISSUE%-build}" ;;
esac

DESIGN_SPEC=""
for cand in $CANDS; do
  DESIGN_SPEC="$(ls docs/superpowers/specs/*-"$cand"-design.md 2>/dev/null | head -1)"
  [ -n "$DESIGN_SPEC" ] && break
done
[ -n "$DESIGN_SPEC" ] || exit 0
# Match `kind: shaping` only in the leading YAML frontmatter (between the first
# two `---` lines). A body mention — common in a design doc *about* shaping,
# including fenced examples — must not trigger the class.
FRONTMATTER="$(awk 'NR==1{ if ($0 != "---") exit; next } /^---[[:space:]]*$/{ exit } { print }' "$DESIGN_SPEC")"
printf '%s\n' "$FRONTMATTER" | grep -qiE '^kind:[[:space:]]*shaping[[:space:]]*$' || exit 0

# A failed or empty diff must NOT classify as a design-doc PR: classify-pr-change
# returns its safe default `docs-config` on empty input, so guarding the file
# list here prevents a bad/unfetched base ref from spuriously scoping reviewers.
FILES="$(git diff "$BASE"...HEAD --name-only 2>/dev/null)" || exit 0
[ -n "$FILES" ] || exit 0
CLASS="$(printf '%s\n' "$FILES" | bash scripts/classify-pr-change.sh --files-from - 2>/dev/null)"
[ "$CLASS" = "docs-config" ] || exit 0

echo "--design-doc"
