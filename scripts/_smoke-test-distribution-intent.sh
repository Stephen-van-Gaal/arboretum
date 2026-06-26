#!/usr/bin/env bash
# owner: arboretum-as-plugin
# scope: plugin-only
# ci-parallel: serial
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

# --- #749: dev-only docs must be excluded from ALL THREE distribution denylists ---
# The dev-only exclude set is duplicated across three publish surfaces, kept in
# sync per arboretum-as-plugin.spec.md:
#   1. .github/workflows/sync-public.yml         (rsync --exclude flags → public repo)
#   2. dev-tools/release/check-release-gate.sh    (dev_only_regex → release gate)
#   3. scripts/stage-codex-plugin-marketplace.sh  (case skips → Codex/agents marketplace)
# A security review found two dev-only docs live in the public repo because they
# were in none of the lists.
SYNC_YML="$ROOT/.github/workflows/sync-public.yml"
RELEASE_GATE="$ROOT/dev-tools/release/check-release-gate.sh"
CODEX_STAGE="$ROOT/scripts/stage-codex-plugin-marketplace.sh"

# The two known leaked paths must be excluded on every surface. The sync pattern
# is root-anchored ('/docs/...') so a like-named example/template doc elsewhere
# still ships; the require_grep patterns tolerate the optional leading slash.
require_grep "--exclude='/?docs/analysis/'" "$SYNC_YML" "public sync excludes docs/analysis (internal cost/strategy)"
require_grep "--exclude='/?docs/walkthrough-outline\\.md'" "$SYNC_YML" "public sync excludes walkthrough-outline stub"
require_grep 'docs/analysis/' "$RELEASE_GATE" "release-gate denylist excludes docs/analysis"
require_grep 'docs/walkthrough-outline' "$RELEASE_GATE" "release-gate denylist excludes walkthrough-outline stub"
require_grep 'docs/analysis' "$CODEX_STAGE" "codex-plugin staging excludes docs/analysis"
require_grep 'docs/walkthrough-outline' "$CODEX_STAGE" "codex-plugin staging excludes walkthrough-outline stub"

# Content-aware guard (#749 finding #2): any tracked docs/*.md carrying a dev-only
# STATUS FIELD ("Status: ... not governed" / "Status: ... analysis") must be
# excluded by ALL THREE publish surfaces — so a future analysis-class doc cannot
# silently leak through a surface someone forgot to update. Keyed on the
# structured Status field (not free text) so template prose that merely mentions
# "not governed" (e.g. docs/templates/plan.md) does not false-trip; the whole
# file is scanned so a marker below the header is still caught.

# Parse dev_only_regex without eval (never execute a foreign assignment line).
dev_only_regex="$(sed -n "s/^dev_only_regex='\\(.*\\)'\$/\\1/p" "$RELEASE_GATE")"

# Does sync-public.yml's rsync exclude list drop this path? Patterns are literal
# dirs (trailing slash) or exact files, optionally root-anchored with '/'.
sync_excludes_path() {
  local p="$1" pat
  while IFS= read -r pat; do
    pat="${pat#/}"
    case "$pat" in
      */) case "$p" in "$pat"*) return 0 ;; esac ;;
      *)  [ "$p" = "$pat" ] && return 0 ;;
    esac
  done < <(grep -oE "exclude='[^']+'" "$SYNC_YML" | sed "s/exclude='//; s/'\$//")
  return 1
}

# Does the Codex staging case-skip block drop this path? Uses the shell's own
# glob matching against each '|'-separated case pattern.
codex_excludes_path() {
  local p="$1" line patterns glob oldifs
  while IFS= read -r line; do
    patterns="${line%%)*}"
    patterns="${patterns#"${patterns%%[![:space:]]*}"}"   # ltrim
    oldifs="$IFS"; IFS='|'
    for glob in $patterns; do
      # shellcheck disable=SC2254 # intentional glob match against case pattern
      case "$p" in $glob) IFS="$oldifs"; return 0 ;; esac
    done
    IFS="$oldifs"
  done < <(grep -E '\) continue ;;' "$CODEX_STAGE")
  return 1
}

if [ -z "$dev_only_regex" ]; then
  fail_msg "could not parse dev_only_regex from release gate (content-aware doc guard)"
else
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    missing=""
    printf '%s\n' "$doc" | grep -Eq "$dev_only_regex" || missing="$missing release-gate"
    sync_excludes_path "$doc" || missing="$missing public-sync"
    codex_excludes_path "$doc" || missing="$missing codex-staging"
    if [ -z "$missing" ]; then
      pass "marked dev-only doc excluded on all surfaces: $doc"
    else
      fail_msg "marked dev-only doc would LEAK — not excluded by:$missing : $doc"
    fi
  done < <(cd "$ROOT" && git ls-files docs | grep -E '\.md$' | while IFS= read -r p; do
             grep -Eqi '^[*_[:space:]]*status[*_[:space:]]*:.*(not governed|analysis)' "$p" 2>/dev/null \
               && printf '%s\n' "$p"
           done)
fi

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
