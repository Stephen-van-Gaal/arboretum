#!/usr/bin/env bash
# owner: arboretum-as-plugin
# stage-codex-plugin-marketplace.sh — materialize a public-shaped local
# marketplace root for Codex plugin install smoke tests.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: stage-codex-plugin-marketplace.sh <empty-destination-dir>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

DEST="$1"

command -v rsync >/dev/null 2>&1 || {
  echo "stage-codex-plugin-marketplace.sh: rsync not found" >&2
  exit 1
}

if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
  echo "stage-codex-plugin-marketplace.sh: destination is not a directory: $DEST" >&2
  exit 1
fi

mkdir -p "$DEST"
if find "$DEST" -mindepth 1 -print -quit | grep -q .; then
  echo "stage-codex-plugin-marketplace.sh: destination must be empty: $DEST" >&2
  exit 1
fi

rsync -a --checksum \
  --exclude='.git/' \
  --exclude='.git' \
  --exclude='.worktrees/' \
  --exclude='docs/specs/' \
  --exclude='docs/plans/' \
  --exclude='docs/superpowers/' \
  --exclude='docs/reviews/' \
  --exclude='docs/dev-contracts/' \
  --exclude='docs/customer-validation/' \
  --exclude='docs/ARCHITECTURE.md' \
  --exclude='docs/reference/' \
  --exclude='.github/' \
  --exclude='customer-testbeds/' \
  --exclude='dev-tools/' \
  --exclude='/CLAUDE.md' \
  --exclude='CLAUDE.public.md' \
  --exclude='README.public.md' \
  --exclude='.agents/skills/' \
  --exclude='.claude/skills/dev-*' \
  --exclude='.claude/skills/_archived/' \
  --exclude='.claude/projects/' \
  --exclude='scripts/_archived/' \
  --exclude='scripts/prepare-customer-testbed.sh' \
  --exclude='scripts/_smoke-test-customer-testbed.sh' \
  --exclude='docs/contracts/prepare-customer-testbed.cli-contract.md' \
  --exclude='docs/REGISTER.md' \
  --exclude='.arboretum.yml' \
  --exclude='.arboretum/' \
  --exclude='.arboretum' \
  --exclude='.gitmodules' \
  --exclude='contracts.yaml' \
  "$ROOT/" "$DEST/"

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

echo "Staged Codex marketplace root: $DEST"
