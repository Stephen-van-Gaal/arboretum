#!/usr/bin/env bash
# owner: arboretum-as-plugin
# stage-codex-plugin-marketplace.sh — materialize a public-shaped local
# marketplace root for Codex plugin install smoke tests.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  echo "usage: stage-codex-plugin-marketplace.sh <empty-destination-dir>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

DEST_INPUT="$1"

command -v rsync >/dev/null 2>&1 || {
  echo "stage-codex-plugin-marketplace.sh: rsync not found" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "stage-codex-plugin-marketplace.sh: git not found" >&2
  exit 1
}

if [ -e "$DEST_INPUT" ] && [ ! -d "$DEST_INPUT" ]; then
  echo "stage-codex-plugin-marketplace.sh: destination is not a directory: $DEST_INPUT" >&2
  exit 1
fi

DEST_PARENT="$(dirname "$DEST_INPUT")"
DEST_NAME="$(basename "$DEST_INPUT")"

case "$DEST_INPUT" in
  "$ROOT"|"$ROOT"/*)
    echo "stage-codex-plugin-marketplace.sh: destination must not be inside source checkout: $DEST_INPUT" >&2
    exit 1
    ;;
esac

if [ ! -d "$DEST_PARENT" ]; then
  echo "stage-codex-plugin-marketplace.sh: destination parent directory does not exist: $DEST_PARENT" >&2
  exit 1
fi

DEST_PARENT_ABS="$(cd "$DEST_PARENT" && pwd -P)"
DEST="$DEST_PARENT_ABS/$DEST_NAME"

case "$DEST/" in
  "$ROOT/"*)
    echo "stage-codex-plugin-marketplace.sh: destination must not be inside source checkout: $DEST" >&2
    exit 1
    ;;
esac

mkdir -p "$DEST"
if find "$DEST" -mindepth 1 -print -quit | grep -q .; then
  echo "stage-codex-plugin-marketplace.sh: destination must be empty: $DEST" >&2
  exit 1
fi

TRACKED_LIST="$(mktemp)"
cleanup_tracked_list() { rm -f "$TRACKED_LIST"; }
trap cleanup_tracked_list EXIT

git -C "$ROOT" ls-files -z | while IFS= read -r -d '' path; do
  case "$path" in
    .git|.git/*) continue ;;
    .worktrees|.worktrees/*) continue ;;
    docs/specs|docs/specs/*) continue ;;
    docs/plans|docs/plans/*) continue ;;
    docs/superpowers|docs/superpowers/*) continue ;;
    docs/reviews|docs/reviews/*) continue ;;
    docs/analysis|docs/analysis/*) continue ;;
    docs/walkthrough-outline.md) continue ;;
    docs/dev-contracts|docs/dev-contracts/*) continue ;;
    docs/customer-validation|docs/customer-validation/*) continue ;;
    docs/ARCHITECTURE.md) continue ;;
    docs/reference|docs/reference/*) continue ;;
    .github|.github/*) continue ;;
    customer-testbeds|customer-testbeds/*) continue ;;
    dev-tools|dev-tools/*) continue ;;
    CLAUDE.md) continue ;;
    CLAUDE.public.md) continue ;;
    README.public.md) continue ;;
    .agents/skills|.agents/skills/*) continue ;;
    .claude/skills/dev-*) continue ;;
    .claude/skills/reflect-dev|.claude/skills/reflect-dev/*) continue ;;
    .claude/skills/_archived|.claude/skills/_archived/*) continue ;;
    # Dogfood web-session mirror entries are symlinks into ../../skills (#757);
    # dev-only, must never reach the staged marketplace (cf. sync-public.yml's
    # find -type l strip). Real dev dirs above are matched first and skipped.
    .claude/skills/*) [ -L "$ROOT/$path" ] && continue ;;
    scripts/generate-web-skill-mirror.sh) continue ;;
    scripts/_smoke-test-contract-web-skill-mirror.sh) continue ;;
    docs/contracts/generate-web-skill-mirror.cli-contract.md) continue ;;
    .claude/projects|.claude/projects/*) continue ;;
    scripts/_archived|scripts/_archived/*) continue ;;
    scripts/prepare-customer-testbed.sh) continue ;;
    scripts/_smoke-test-customer-testbed.sh) continue ;;
    docs/contracts/prepare-customer-testbed.cli-contract.md) continue ;;
    docs/REGISTER.md) continue ;;
    .arboretum.yml) continue ;;
    .arboretum|.arboretum/*) continue ;;
    .gitmodules) continue ;;
    contracts.yaml)
      continue
      ;;
  esac
  printf '%s\0' "$path"
done >"$TRACKED_LIST"

rsync -a --checksum --from0 --files-from="$TRACKED_LIST" "$ROOT/" "$DEST/"

if [ -f "$ROOT/.github/ISSUE_TEMPLATE/arboretum-problem.md" ]; then
  mkdir -p "$DEST/.github/ISSUE_TEMPLATE"
  cp "$ROOT/.github/ISSUE_TEMPLATE/arboretum-problem.md" "$DEST/.github/ISSUE_TEMPLATE/"
fi
if [ -f "$ROOT/.github/ISSUE_TEMPLATE/arboretum-enhancement.md" ]; then
  mkdir -p "$DEST/.github/ISSUE_TEMPLATE"
  cp "$ROOT/.github/ISSUE_TEMPLATE/arboretum-enhancement.md" "$DEST/.github/ISSUE_TEMPLATE/"
fi

if [ -f "$ROOT/CLAUDE.public.md" ]; then
  cp "$ROOT/CLAUDE.public.md" "$DEST/CLAUDE.md"
elif [ -f "$ROOT/CLAUDE.md" ]; then
  cp "$ROOT/CLAUDE.md" "$DEST/CLAUDE.md"
fi

if [ -f "$ROOT/README.public.md" ]; then
  cp "$ROOT/README.public.md" "$DEST/README.md"
elif [ -f "$ROOT/README.md" ]; then
  cp "$ROOT/README.md" "$DEST/README.md"
fi

if [ -f "$DEST/scripts/generate-coverage.sh" ] && [ -d "$DEST/docs/contracts" ]; then
  (cd "$DEST" && bash scripts/generate-coverage.sh >/dev/null)
fi

echo "Staged Codex marketplace root: $DEST"
