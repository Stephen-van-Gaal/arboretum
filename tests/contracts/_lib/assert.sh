#!/usr/bin/env bash
# owner: pipeline-contracts-template
# tests/contracts/_lib/assert.sh — Shared test helpers for contract tests.
#
# All helpers print FAIL: <reason> to stderr and return 1 on assertion
# failure; return 0 on success. Tests source this file and call helpers
# in sequence; any non-zero return propagates if the calling test uses
# `set -e` (recommended).

# assertExit <expected_code> <actual_code> <context>
assertExit() {
  local expected="$1"
  local actual="$2"
  local context="${3:-exit code}"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $context — expected exit $expected, got $actual" >&2
    return 1
  fi
  return 0
}

# assertContains <haystack_file> <needle_substring> <context>
assertContains() {
  local file="$1"
  local needle="$2"
  local context="${3:-content}"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL: $context — expected '$needle' in $file" >&2
    echo "  Actual contents:" >&2
    sed 's/^/    /' "$file" >&2
    return 1
  fi
  return 0
}

# assertNotContains <haystack_file> <needle_substring> <context>
assertNotContains() {
  local file="$1"
  local needle="$2"
  local context="${3:-content}"
  if grep -qF -- "$needle" "$file"; then
    echo "FAIL: $context — '$needle' should not appear in $file" >&2
    return 1
  fi
  return 0
}

# assertStderr <stderr_file> <needle_substring> <context>
# Alias for assertContains; named for readability when checking stderr.
assertStderr() {
  assertContains "$1" "$2" "${3:-stderr}"
}

# assertStdout <stdout_file> <needle_substring> <context>
assertStdout() {
  assertContains "$1" "$2" "${3:-stdout}"
}

# pass <test_name> — log pass marker (used by tests with multiple assertions)
pass() {
  echo "PASS: ${1:-(unnamed)}"
}
