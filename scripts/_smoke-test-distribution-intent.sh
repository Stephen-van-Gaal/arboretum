#!/usr/bin/env bash
# owner: arboretum-as-plugin
# Smoke test for Arboretum's dev-only/public-plugin/consumer-managed boundary.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

pass() { printf 'ok: %s\n' "$1"; }
fail_msg() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

require_grep() {
  pattern="$1"
  file="$2"
  label="$3"
  if [ ! -f "$file" ]; then
    fail_msg "$label (missing file: ${file#$ROOT/})"
    return
  fi
  if grep -Eq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

forbid_grep() {
  pattern="$1"
  file="$2"
  label="$3"
  if [ ! -f "$file" ]; then
    fail_msg "$label (missing file: ${file#$ROOT/})"
    return
  fi
  if grep -Eq -- "$pattern" "$file"; then
    fail_msg "$label"
  else
    pass "$label"
  fi
}

require_grep "--exclude='dev-tools/'" "$ROOT/.github/workflows/sync-public.yml" "public sync excludes dev-tools"
require_grep "--exclude='\\.claude/skills/reflect-dev/'" "$ROOT/.github/workflows/sync-public.yml" "public sync excludes reflect-dev dogfood skill"
require_grep "--exclude='scripts/_smoke-test-reflect-dev\\.sh'" "$ROOT/.github/workflows/sync-public.yml" "public sync excludes reflect-dev dogfood smoke test"
require_grep 'Distribution intent by directory' "$ROOT/docs/specs/arboretum-as-plugin.spec.md" "arboretum-as-plugin spec defines directory contract"
require_grep 'dev-tools/release' "$ROOT/docs/specs/arboretum-as-plugin.spec.md" "arboretum-as-plugin spec names dev-only release tooling"

for skill in "$ROOT/skills/pr/SKILL.md" "$ROOT/skills/finish/SKILL.md" "$ROOT/skills/land/SKILL.md" "$ROOT/skills/cleanup/SKILL.md"; do
  forbid_grep 'Release Intent|release-impact|release-state|prepare-release-package\.sh' "$skill" "public skill has no dev-only release-lane prose: ${skill#$ROOT/}"
done

for path in \
  "$ROOT/dev-tools/release/check-release-gate.sh" \
  "$ROOT/dev-tools/release/check-version-bump.sh" \
  "$ROOT/dev-tools/release/read-release-intent.sh" \
  "$ROOT/dev-tools/release/prepare-release-package.sh" \
  "$ROOT/dev-tools/release/bump-version.sh"
do
  [ -f "$path" ] || fail_msg "dev-only release helper missing: ${path#$ROOT/}"
done

for path in \
  "$ROOT/scripts/check-release-gate.sh" \
  "$ROOT/scripts/check-version-bump.sh" \
  "$ROOT/scripts/read-release-intent.sh" \
  "$ROOT/scripts/prepare-release-package.sh" \
  "$ROOT/scripts/bump-version.sh"
do
  [ ! -f "$path" ] || fail_msg "release helper moved out of scripts: ${path#$ROOT/}"
done

[ "$fail" = 0 ] && echo "ok: distribution intent"
exit "$fail"
