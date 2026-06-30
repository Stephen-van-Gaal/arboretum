#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-9
# pipeline-version: unified
#
# Asserts the kind: shaping substrate-survey requirement (#934):
#   - a shaping doc WITHOUT a non-empty `## Substrate Survey` section is rejected
#     (exit 1, stderr names `Substrate Survey`)
#   - a shaping doc WITH the section passes (exit 0)
#   - a buildable doc without the section is unaffected (exit 0)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

VALIDATE="$ROOT/scripts/validate-design-spec.sh"
FIX="$ROOT/tests/contracts/fixtures"
err_out=$(mktemp)
trap 'rm -f "$err_out"' EXIT

# Absent section on a shaping doc → exit 1 naming the field.
bash "$VALIDATE" "$FIX/design-shaping-no-substrate.md" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "validate rejects shaping doc missing Substrate Survey" || exit 1
assertStderr "$err_out" "Substrate Survey" "S2-9 names the missing section" || exit 1

# Heading only inside a code fence does NOT count → exit 1 (missing).
bash "$VALIDATE" "$FIX/design-shaping-fenced-substrate.md" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "validate rejects shaping doc whose heading is only inside a code fence" || exit 1
assertStderr "$err_out" "Substrate Survey" "S2-9 fenced-heading does not satisfy the floor" || exit 1

# Heading fenced in a ``` block containing a ~~~ line → still fenced → exit 1.
bash "$VALIDATE" "$FIX/design-shaping-fence-mismatch-substrate.md" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "validate rejects heading fenced by a backtick block despite an inner tilde line" || exit 1
assertStderr "$err_out" "Substrate Survey" "S2-9 fence family is tracked to the opener" || exit 1

# Heading present but empty (no content before next heading) → exit 1 (empty).
bash "$VALIDATE" "$FIX/design-shaping-empty-substrate.md" 2>"$err_out"
rc=$?
assertExit 1 "$rc" "validate rejects shaping doc with empty Substrate Survey" || exit 1
assertStderr "$err_out" "Substrate Survey" "S2-9 names the empty section" || exit 1

# Present section on a shaping doc → exit 0.
bash "$VALIDATE" "$FIX/design-shaping-good.md" >/dev/null 2>"$err_out"
rc=$?
assertExit 0 "$rc" "validate accepts shaping doc with Substrate Survey" || exit 1

# A survey that opens with a deeper subheading (H3) / #-prefixed content is NOT
# empty — only a new H1/H2 heading ends the section → exit 0.
bash "$VALIDATE" "$FIX/design-shaping-subheading-substrate.md" >/dev/null 2>"$err_out"
rc=$?
assertExit 0 "$rc" "validate accepts shaping survey opening with an H3 subheading" || exit 1

# Buildable doc without the section → unaffected (exit 0).
bash "$VALIDATE" "$FIX/design-good.md" >/dev/null 2>"$err_out"
rc=$?
assertExit 0 "$rc" "buildable doc unaffected by S2-9" || exit 1

pass "S2-9 substrate-survey"
