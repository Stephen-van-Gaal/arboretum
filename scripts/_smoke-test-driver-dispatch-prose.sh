#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# _smoke-test-driver-dispatch-prose.sh — Guards the codified fresh-context-driver
# dispatch idiom (#720). The invariant lives once in skill-and-agent-authoring.spec.md;
# /finish Step 5 must apply it (generic subagent + invoke skill), never naming a
# lane/skill as subagent_type.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

SPEC="docs/specs/skill-and-agent-authoring.spec.md"
FINISH="skills/finish/SKILL.md"

# Prose wraps across lines; flatten newlines to spaces so multi-token phrases
# are not held hostage to the column at which an author happened to wrap.
flat() { tr '\n' ' ' < "$1"; }
SPEC_FLAT="$(flat "$SPEC")"
FINISH_FLAT="$(flat "$FINISH")"

# (a) The single source exists with the invariant.
grep -q '^### Fresh-context driver dispatch' "$SPEC" \
  || fail "canonical '### Fresh-context driver dispatch' section missing from $SPEC"
printf '%s' "$SPEC_FLAT" | grep -Eqi 'never (be )?(passed|used) as[^.]*subagent_type|name is (never|not) (a |the )?subagent_type' \
  || fail "name-is-never-subagent_type invariant missing from $SPEC dispatch section"
ok "single-source dispatch idiom + invariant present"

# (b) /finish Step 5 applies the idiom: generic subagent + invoke each lane skill.
printf '%s' "$FINISH_FLAT" | grep -qi 'general-purpose' \
  || fail "$FINISH Step 5 does not name a generic (general-purpose) subagent"
for skill in '/ai-surface-review' '/security-review' '/code-review'; do
  printf '%s' "$FINISH_FLAT" | grep -Eqi "invoke.*${skill}" \
    || fail "$FINISH does not instruct invoking ${skill}"
done
ok "/finish Step 5 uses generic-subagent + invoke-skill idiom"

# (b-guard) No instruction to pass a lane/skill name as subagent_type. Strip
# backticks/quotes first so wrapped values are caught, and allow an optional
# plugin-prefix segment (arboretum:) AND an optional leading slash — covering the
# bare, backtick/quote-wrapped, plugin-prefixed, and slash-command regression shapes.
FINISH_NOQUOTE="$(printf '%s' "$FINISH_FLAT" | tr -d '`"'\''')"
printf '%s' "$FINISH_NOQUOTE" | grep -Eqi 'subagent_type[:= ]*([a-z][a-z-]*:)?/?(ai-surface-review|security-review|code-review)' \
  && fail "$FINISH instructs passing a lane/skill name as subagent_type (the #720 bug)"
ok "no lane/skill name used as subagent_type"

echo "ALL PASS: driver-dispatch prose"
