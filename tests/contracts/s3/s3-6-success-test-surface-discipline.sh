#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s3-build-to-finish
# assertion: S3-6
# pipeline-version: v2
#
# Asserts: validate-test-surface.sh accepts a spec/list pair that
# satisfies the contract rule (block present + every file listed),
# and rejects a pair where files changed but the spec lacks the
# block. Fixture-driven — no hard-coded spec paths.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Good case: spec has block, list matches
err_out=$(mktemp)
bash "$ROOT/scripts/validate-test-surface.sh" \
  "$ROOT/tests/contracts/fixtures/design-with-test-surface.md" \
  "$ROOT/tests/contracts/fixtures/test-surface-list-good.txt" 2>"$err_out"
assertExit 0 "$?" "good pair accepted" || { rm -f "$err_out"; exit 1; }

# Bad case: spec is design-good.md (no test-surface-changes block) + non-empty list
bash "$ROOT/scripts/validate-test-surface.sh" \
  "$ROOT/tests/contracts/fixtures/design-good.md" \
  "$ROOT/tests/contracts/fixtures/test-surface-list-bad.txt" 2>"$err_out"
assertExit 1 "$?" "bad pair rejected" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "S3-6" "S3-6 stderr" || { rm -f "$err_out"; exit 1; }

# Regression for Codex round-2 P2 #1: regex-metachar in filename. The
# spec block lists `foo-testXsh`; the changed-files list names
# `foo-test.sh`. Under the original regex-token matcher, the `.` in
# `.sh` was treated as a wildcard, falsely matching `Xsh`. Token-set
# match (current impl) correctly rejects.
bash "$ROOT/scripts/validate-test-surface.sh" \
  "$ROOT/tests/contracts/fixtures/design-with-test-surface-metachar.md" \
  "$ROOT/tests/contracts/fixtures/test-surface-list-good.txt" 2>"$err_out"
assertExit 1 "$?" "metachar near-miss rejected" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "test file tests/example/foo_test.sh changed but not listed" "metachar stderr names file" || { rm -f "$err_out"; exit 1; }

# Regression for Codex round-2 P2 #2: YAML-quoted entry form. The spec
# block uses `- "tests/example/foo_test.sh"`; the changed-files list
# names the same file unquoted. Under the original regex boundary, the
# closing `"` wasn't in the trailing-char class, so the entry was
# treated as absent. Token-set match strips the quotes correctly.
bash "$ROOT/scripts/validate-test-surface.sh" \
  "$ROOT/tests/contracts/fixtures/design-with-test-surface-quoted.md" \
  "$ROOT/tests/contracts/fixtures/test-surface-list-good.txt" 2>"$err_out"
assertExit 0 "$?" "YAML-quoted entry accepted" || { rm -f "$err_out"; exit 1; }

# Regression for Codex round-3 P2 #2: reason-bearing entry. S3-6's
# contract explicitly says `test-surface-changes:` entries are "named
# with a reason" — `- tests/foo.sh — added for X` is the contract-
# compliant form. The post-round-2 regex was anchored to `$` immediately
# after the (optional) trailing comma, so any reason text after the
# filename caused the line to silently NOT match → false S3-6 failure.
bash "$ROOT/scripts/validate-test-surface.sh" \
  "$ROOT/tests/contracts/fixtures/design-with-test-surface-reasons.md" \
  "$ROOT/tests/contracts/fixtures/test-surface-list-good.txt" 2>"$err_out"
assertExit 0 "$?" "reason-bearing entry accepted" || { cat "$err_out" >&2; rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S3-6"
