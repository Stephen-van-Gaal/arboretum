#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-resolve-stage-model.sh — resolve-stage-model.sh contract:
# layered precedence (override ?? frontmatter floor ?? SESSION_DEFAULT) and
# fail-loud on an invalid family at any layer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skills/demo"

fail=0; fail(){ echo "FAIL: $1" >&2; fail=$((fail+1)); }; pass(){ echo "PASS: $1"; }
run(){ bash "$ROOT/scripts/resolve-stage-model.sh" "$@"; }

# Floor only (frontmatter) -> capable id
printf -- '---\nname: demo\ndefault-model: capable\n---\nbody\n' > "$TMP/skills/demo/SKILL.md"
out="$(run demo --skills-root "$TMP/skills" --config "$TMP/none.yml")"
[ "$out" = "claude-sonnet-5" ] && pass "floor capable -> sonnet" || fail "floor got '$out'"

# No floor -> SESSION_DEFAULT
printf -- '---\nname: demo\n---\nbody\n' > "$TMP/skills/demo/SKILL.md"
out="$(run demo --skills-root "$TMP/skills" --config "$TMP/none.yml")"
[ "$out" = "SESSION_DEFAULT" ] && pass "no floor -> SESSION_DEFAULT" || fail "no floor got '$out'"

# Override beats floor
printf -- '---\nname: demo\ndefault-model: capable\n---\nbody\n' > "$TMP/skills/demo/SKILL.md"
printf 'workflow:\n  stage_models:\n    demo: cheap\n' > "$TMP/cfg.yml"
out="$(run demo --skills-root "$TMP/skills" --config "$TMP/cfg.yml")"
[ "$out" = "claude-haiku-4-5" ] && pass "override beats floor" || fail "override got '$out'"

# Invalid family (floor layer) fails loud
printf -- '---\nname: demo\ndefault-model: bogus\n---\nbody\n' > "$TMP/skills/demo/SKILL.md"
if run demo --skills-root "$TMP/skills" --config "$TMP/none.yml" 2>/dev/null; then
  fail "invalid family (floor) did not error"
else
  pass "invalid family (floor) fails loud"
fi

# Invalid family (override layer) fails loud — proves fail-loud at the override
# layer, not just the floor (the contract promises "any layer").
printf -- '---\nname: demo\n---\nbody\n' > "$TMP/skills/demo/SKILL.md"
printf 'workflow:\n  stage_models:\n    demo: bogus\n' > "$TMP/cfg.yml"
if run demo --skills-root "$TMP/skills" --config "$TMP/cfg.yml" 2>/dev/null; then
  fail "invalid family (override) did not error"
else
  pass "invalid family (override) fails loud"
fi

# Present-but-unparseable config fails loud (not a silent override drop)
printf '\t\tnot: [valid\n  : : :\n' > "$TMP/bad.yml"
if run demo --skills-root "$TMP/skills" --config "$TMP/bad.yml" 2>/dev/null; then
  fail "malformed config did not error (silent override drop)"
else
  pass "malformed config fails loud"
fi

# Invalid skill name is rejected (regex-metachar / ReDoS guard)
if run 'demo$(touch pwned)' --skills-root "$TMP/skills" --config "$TMP/none.yml" 2>/dev/null; then
  fail "invalid skill name accepted"
else
  pass "invalid skill name rejected"
fi

# Missing skill name -> usage error (exit 2)
if run --skills-root "$TMP/skills" 2>/dev/null; then
  fail "missing skill name did not error"
else
  pass "missing skill name errors"
fi

[ "$fail" -eq 0 ] || { echo "" >&2; echo "FAIL: $fail assertion(s)" >&2; exit 1; }
echo "PASS: resolve-stage-model"
