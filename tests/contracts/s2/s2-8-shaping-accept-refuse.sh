#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-8
# pipeline-version: unified
#
# Asserts the kind: shaping accept-and-refuse surface (#692):
#   - validate-design-spec.sh accepts a shaping doc with only related-issue
#   - read-s2-frontmatter.sh refuses it with exit 3 (non-buildable)
#   - an out-of-enum kind value is a validation error naming the field
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

VALIDATE="$ROOT/scripts/validate-design-spec.sh"
READ="$ROOT/scripts/read-s2-frontmatter.sh"
SHAPING="$ROOT/tests/contracts/fixtures/design-shaping-good.md"
BAD_KIND="$ROOT/tests/contracts/fixtures/design-bad-kind.md"

# Producer side: validator accepts kind: shaping (identity-only).
bash "$VALIDATE" "$SHAPING" >/dev/null 2>&1
assertExit 0 "$?" "validate-design-spec accepts $SHAPING" || exit 1

# Consumer side: read-s2 refuses with the distinct exit 3 + shaping message.
err_out=$(mktemp)
bash "$READ" "$SHAPING" >/dev/null 2>"$err_out"
rc=$?
assertExit 3 "$rc" "read-s2-frontmatter refuses $SHAPING" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "shaping" "S2-8 refusal message" || { rm -f "$err_out"; exit 1; }

# Out-of-enum kind is rejected independently by BOTH gates (self-contained).
# Producer: validate-design-spec.sh exit 1 naming the field.
bash "$VALIDATE" "$BAD_KIND" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "validate-design-spec rejects bad kind" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "kind: not in" "S2-8 bad-kind validator stderr" || { rm -f "$err_out"; exit 1; }

# Consumer: read-s2-frontmatter.sh exit 2 (drift) — must not treat bad kind as
# buildable even though design-bad-kind.md carries complete five fields.
bash "$READ" "$BAD_KIND" >/dev/null 2>"$err_out"
rc=$?
assertExit 2 "$rc" "read-s2-frontmatter rejects bad kind as drift" || { rm -f "$err_out"; exit 1; }
assertStderr "$err_out" "invalid kind" "S2-8 bad-kind reader stderr" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S2-8"
