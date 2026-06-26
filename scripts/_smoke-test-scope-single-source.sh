#!/usr/bin/env bash
# owner: framework-scope-marker
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-scope-single-source.sh — the `# scope:` marker grammar is parsed
# in exactly one place (scripts/lib/scope-resolve.sh). Consumers must source the
# helper and must NOT re-inline a `# scope:` parsing regex (the parallel-drift
# class of #124). Mirrors the SCC-3 single-sourcing contract for scrub.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }

for f in scripts/ci-checks.sh scripts/health-check.sh; do
  # Must source the single-source helper.
  grep -q 'lib/scope-resolve.sh' "$ROOT/$f" \
    && pass "$f sources scope-resolve.sh" \
    || bad "$f does not source scope-resolve.sh"

  # Must NOT re-inline a `# scope:` parsing regex. The anchored form `^# scope:`
  # only appears inside a parser; each file's own marker line is the un-anchored
  # `# scope: plugin-only`, so this is a precise signal.
  if grep -Fq '^# scope:' "$ROOT/$f"; then
    bad "$f re-inlines a '^# scope:' parsing regex — use file_scope from scope-resolve.sh"
  else
    pass "$f has no inlined scope parser"
  fi
done

# The marker-value alternation grammar lives only in the helper.
others=$(grep -rlE '\(plugin-only\|consumer\|any\)' "$ROOT/scripts" 2>/dev/null \
          | grep -v 'scripts/lib/scope-resolve.sh' || true)
[ -z "$others" ] \
  && pass "marker alternation grammar is single-sourced" \
  || bad "marker alternation grammar also appears in: $others"

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
