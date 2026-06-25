#!/usr/bin/env bash
# owner: review-stage
# _smoke-test-review-dispatch.sh — assert the lane planner emits, in run order:
#   ai-surface (only when AI-facing surface changed), general-security (always),
#   correctness (only when the diff contains code per classify-pr-change.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="$SCRIPT_DIR/review-dispatch.sh"
fail_count=0
check() { # <label> <expected-newline-joined> <files...>
  local label="$1" expected="$2"; shift 2
  local got
  got=$(printf '%s\n' "$@" | bash "$PLAN" --files-from -)
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $label — expected '$expected', got '$got'" >&2
    ((fail_count++)) || true
  fi
}
check "ai-facing code (skill)" $'ai-surface\ngeneral-security\ncorrectness' "skills/finish/SKILL.md"
check "ai-facing code (hook)"  $'ai-surface\ngeneral-security\ncorrectness' ".claude/hooks/session-start.sh"
check "ai-facing docs (md)"    $'ai-surface\ngeneral-security'              "CLAUDE.md"
check "conventional code"      $'general-security\ncorrectness'            "src/app.ts"
check "docs only"              "general-security"                          "README.md" "docs/x.md"
check "empty diff"             "general-security"
check "mixed surface+code"     $'ai-surface\ngeneral-security\ncorrectness' "skills/finish/SKILL.md" "src/app.ts"

# --- verdict mode (#854) ---
vcheck() { # <label> <lane> <expected-relevant true|false> <files...>
  local label="$1" lane="$2" want="$3"; shift 3
  local got
  got=$(printf '%s\n' "$@" | bash "$PLAN" --verdicts --files-from - | jq -r ".lanes[\"$lane\"].relevant")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label — $lane.relevant expected '$want', got '$got'" >&2
    ((fail_count++)) || true
  fi
}
vany() { # <label> <expected any_relevant> <files...>
  local label="$1" want="$2"; shift 2
  local got
  got=$(printf '%s\n' "$@" | bash "$PLAN" --verdicts --files-from - | jq -r '.any_relevant')
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label — any_relevant expected '$want', got '$got'" >&2
    ((fail_count++)) || true
  fi
}

# ALLOWLIST: general-security skips ONLY for provably-safe prose; everything else keeps it.
# safe prose: root README.md/CHANGELOG.md, *.txt anywhere, DIRECT docs/*.md.
vcheck "safe prose / general-security" general-security false "README.md" "docs/x.md"
vcheck "safe prose / correctness"      correctness      false "README.md" "docs/x.md"
vany   "safe prose / any"              false             "README.md" "docs/x.md"
vcheck "txt + direct docs / gen-sec"   general-security false "docs/guide.md" "notes.txt"

# Config keeps security (not in allowlist).
vcheck "settings.json / general-sec"   general-security true  ".claude/settings.json"
vcheck "yaml config / general-sec"     general-security true  "reviewers.yml"
vcheck "ci workflow / general-sec"     general-security true  ".github/workflows/ci.yml"
vcheck "github md / general-sec"       general-security true  ".github/ISSUE_TEMPLATE/agent-ready.md"

# Code keeps security + correctness.
vcheck "code / correctness"      correctness      true  "src/app.ts"
vcheck "code / general-sec"      general-security true  "src/app.ts"

# AI-facing surface -> ai-surface relevant (lane-list unchanged from v1.0: root instruction files).
vcheck "ai-surface / relevant"   ai-surface       true  "skills/finish/SKILL.md"
# Skill / instruction markdown keeps general-security (not in allowlist).
vcheck "skill md / general-sec"  general-security true  "skills/finish/SKILL.md"
vcheck "claude.md / ai-surface"  ai-surface       true  "CLAUDE.md"
vcheck "claude.md / general-sec" general-security true  "CLAUDE.md"
# Agent-facing docs that are NOT in the allowlist keep security (Codex P2 rounds 3-4):
vcheck "nested agents / gen-sec" general-security true  "docs/templates/AGENTS.md"
vcheck "nested docs / gen-sec"   general-security true  "docs/specs/foo.spec.md"
vcheck "workflow doc / gen-sec"  general-security true  "workflows/build.md"
vcheck "ARBORETUM.md / gen-sec"  general-security true  "ARBORETUM.md"
# *.rst keeps security (allowlist excludes it; classify-pr-change treats root *.rst as code).
vcheck "rst / general-sec"       general-security true  "CHANGELOG.rst"

if [ "$fail_count" -gt 0 ]; then
  echo "FAIL: $fail_count case(s) failed" >&2; exit 1
fi
echo "PASS: review-dispatch.sh — verdicts + lane-list"
