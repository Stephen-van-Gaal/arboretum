#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Smoke test: detect-design-doc-pr.sh — emits "--design-doc" only when the
# current branch is a design-doc PR (kind:shaping design spec resolvable by the
# §5.5 branch-slug convention INCLUDING issue-prefixed branches, AND a
# docs-config diff). Single source for the design-doc class (#935), consumed by
# /pr and /land.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/detect-design-doc-pr.sh"
fail=0
note() { echo "FAIL: $1"; fail=1; }

# Build a throwaway git repo: main has a baseline; a feature branch adds a
# kind:shaping design spec (docs-only). detect must emit --design-doc.
mk_repo() { # $1 = dir
  local d="$1"
  mkdir -p "$d/scripts" "$d/docs/superpowers/specs"
  cp "$SCRIPT_DIR/classify-pr-change.sh" "$d/scripts/classify-pr-change.sh"
  (
    cd "$d" || exit
    git init -q
    git branch -M main          # base branch must be 'main' for the diff range
    git config user.email t@t.t; git config user.name t
    echo baseline > README.md
    git add README.md scripts/classify-pr-change.sh
    git commit -qm base
  )
}

# --- 1. issue-prefixed branch + kind:shaping docs-only diff => --design-doc ---
r1="$(mktemp -d)"; mk_repo "$r1"
(
  cd "$r1" || exit
  git checkout -q -b feat/935-codex-design-review
  printf -- '---\nkind: shaping\nrelated-issue: 935\n---\n# x\n' \
    > docs/superpowers/specs/2026-06-28-codex-design-review-design.md
  git add docs/superpowers/specs/*.md
  git commit -qm "shaping doc"
)
out="$(cd "$r1" && bash "$DETECT" main 2>/dev/null)"
[ "$out" = "--design-doc" ] || note "issue-prefixed shaping docs-only branch should emit --design-doc (got '$out')"
rm -rf "$r1"

# --- 2. buildable (no kind:shaping) => empty ---
r2="$(mktemp -d)"; mk_repo "$r2"
(
  cd "$r2" || exit
  git checkout -q -b feat/600-some-feature
  printf -- '---\nrelated-issue: 600\n---\n# x\n' \
    > docs/superpowers/specs/2026-06-28-some-feature-design.md
  git add docs/superpowers/specs/*.md
  git commit -qm "buildable doc"
)
out="$(cd "$r2" && bash "$DETECT" main 2>/dev/null)"
[ -z "$out" ] || note "buildable (non-shaping) branch must NOT emit --design-doc (got '$out')"
rm -rf "$r2"

# --- 3. kind:shaping but diff contains CODE => empty (classifier is the gate) ---
r3="$(mktemp -d)"; mk_repo "$r3"
(
  cd "$r3" || exit
  git checkout -q -b feat/700-mixed
  printf -- '---\nkind: shaping\nrelated-issue: 700\n---\n# x\n' \
    > docs/superpowers/specs/2026-06-28-mixed-design.md
  mkdir -p skills/foo; echo "# owner: x" > skills/foo/SKILL.md
  git add docs/superpowers/specs/*.md skills/foo/SKILL.md
  git commit -qm "shaping + skill code"
)
out="$(cd "$r3" && bash "$DETECT" main 2>/dev/null)"
[ -z "$out" ] || note "a code-bearing diff must NOT classify as a design-doc PR (got '$out')"
rm -rf "$r3"

# --- 4. a bad/unresolvable base ref must degrade to empty, not --design-doc ---
r4="$(mktemp -d)"; mk_repo "$r4"
(
  cd "$r4" || exit
  git checkout -q -b feat/935-codex-design-review
  printf -- '---\nkind: shaping\nrelated-issue: 935\n---\n# x\n' \
    > docs/superpowers/specs/2026-06-28-codex-design-review-design.md
  git add docs/superpowers/specs/*.md
  git commit -qm "shaping doc"
)
out="$(cd "$r4" && bash "$DETECT" no-such-base 2>/dev/null)"
[ -z "$out" ] || note "a bad base ref must degrade to empty (empty diff != design-doc) (got '$out')"
# CR2-1: an empty base-ref arg must also degrade to empty + exit 0 (no usage error).
out="$(cd "$r4" && bash "$DETECT" "" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || note "empty base ref must exit 0 (contract: always 0), got $rc"
[ -z "$out" ] || note "empty base ref must emit nothing (got '$out')"
rm -rf "$r4"

# --- 5. kind:shaping only in the BODY (not frontmatter) must NOT match (#935 R2-2) ---
r5="$(mktemp -d)"; mk_repo "$r5"
(
  cd "$r5" || exit
  git checkout -q -b feat/800-doc-about-shaping
  # frontmatter has NO kind:; the body discusses kind: shaping (prose + a fence).
  {
    printf -- '---\nrelated-issue: 800\ntriage: everything-else\n---\n'
    printf '# A design doc about the shaping flow\n\n'
    printf 'A `kind: shaping` session exits to /finish. Example frontmatter:\n\n'
    printf '```\nkind: shaping\n```\n'
  } > docs/superpowers/specs/2026-06-28-doc-about-shaping-design.md
  git add docs/superpowers/specs/*.md
  git commit -qm "doc that mentions shaping in its body"
)
out="$(cd "$r5" && bash "$DETECT" main 2>/dev/null)"
[ -z "$out" ] || note "a body-only 'kind: shaping' mention must NOT classify as a design-doc PR (got '$out')"
rm -rf "$r5"

[ "$fail" -eq 0 ] && echo "PASS: detect-design-doc-pr" || exit 1
