#!/usr/bin/env bash
# owner: pipeline-contracts-template
# test_assert.sh — Sanity test for assert.sh helpers.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
. "$LIB/assert.sh"

failed=0

# Use mktemp instead of a fixed /tmp path — concurrent test runs (e.g.
# parallel CI matrix) would collide on the fixed name, and a pre-
# existing file with wrong perms would fail the haystack write silently.
HAYSTACK=$(mktemp)
trap 'rm -f "$HAYSTACK"' EXIT

# assertExit — pass case
if ! assertExit 0 0 "expected-pass" 2>/dev/null; then
  echo "REGRESSION: assertExit 0 0 returned non-zero" >&2
  failed=1
fi

# assertExit — fail case
if assertExit 0 1 "expected-fail" 2>/dev/null; then
  echo "REGRESSION: assertExit 0 1 returned zero" >&2
  failed=1
fi

# assertContains — pass case
echo "hello world" > "$HAYSTACK"
if ! assertContains "$HAYSTACK" "world" "expected-pass" 2>/dev/null; then
  echo "REGRESSION: assertContains hit-case returned non-zero" >&2
  failed=1
fi

# assertContains — fail case
if assertContains "$HAYSTACK" "nope" "expected-fail" 2>/dev/null; then
  echo "REGRESSION: assertContains miss-case returned zero" >&2
  failed=1
fi

# assertNotContains — inverse of above
if ! assertNotContains "$HAYSTACK" "nope" "expected-pass" 2>/dev/null; then
  echo "REGRESSION: assertNotContains miss-case returned non-zero" >&2
  failed=1
fi
if assertNotContains "$HAYSTACK" "world" "expected-fail" 2>/dev/null; then
  echo "REGRESSION: assertNotContains hit-case returned zero" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "test_assert.sh: REGRESSIONS DETECTED" >&2
  exit 1
fi
echo "test_assert.sh: all helper assertions passed"
exit 0
