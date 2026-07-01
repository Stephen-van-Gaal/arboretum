#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-driver-model-floors.sh — #923/#924: the four shipped
# read-only drivers carry a family floor and resolve a model at their dispatch
# site, and the conductor stamps stage+model into the ledger. Floors:
#   cleanup            -> cheap     (frontmatter)
#   land (assess)      -> capable   (frontmatter)
#   ai-surface-review  -> capable   (frontmatter)
#   general-security   -> capable   (.arboretum.yml override; /security-review
#                                    is a built-in with no arboretum frontmatter)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0; fail(){ echo "FAIL: $1" >&2; fail=$((fail+1)); }; pass(){ echo "PASS: $1"; }

fm_floor(){ { bash "$ROOT/scripts/lib/yaml-lite.sh" frontmatter "$ROOT/$1" 2>/dev/null \
  | grep -E '^default-model=' | head -n1 | cut -d= -f2-; } || true; }

# 1. Frontmatter floors on the three skill-backed stages.
check_fm(){ local f="$1" want="$2" lbl="$3"; got="$(fm_floor "$f")"
  [ "$got" = "$want" ] && pass "$lbl frontmatter floor=$want" || fail "$lbl floor got '$got' want '$want'"; }
check_fm skills/cleanup/SKILL.md cheap "cleanup"
check_fm skills/land/SKILL.md capable "land"
check_fm skills/ai-surface-review/SKILL.md capable "ai-surface-review"

# 2. general-security floored via .arboretum.yml override — resolved end-to-end.
gs="$(bash "$ROOT/scripts/resolve-stage-model.sh" general-security 2>/dev/null || true)"
[ "$gs" = "claude-sonnet-5" ] && pass "general-security override -> capable id" \
  || fail "general-security resolved '$gs' want claude-sonnet-5 (capable)"

# 3. Each dispatcher references the resolver at its dispatch site.
for f in skills/cleanup/SKILL.md skills/land/SKILL.md skills/finish/SKILL.md; do
  grep -q "resolve-stage-model.sh" "$ROOT/$f" && pass "$f calls resolver" || fail "$f no resolver call"
done

# 4. Conductor stamps stage into the ledger at the cleanup/land dispatch boundary.
for f in skills/cleanup/SKILL.md skills/land/SKILL.md; do
  grep -q "ARBORETUM_STAGE" "$ROOT/$f" && pass "$f stamps ARBORETUM_STAGE" || fail "$f no stage stamp"
done

[ "$fail" -eq 0 ] || { echo "" >&2; echo "FAIL: $fail assertion(s)" >&2; exit 1; }
echo "PASS: driver model floors"
