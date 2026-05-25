#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s2-design-to-build
# assertion: S2-7
# pipeline-version: v2
#
# Asserts the validator-as-single-source-of-truth binding (WS4 D4): both
# the S2 producer skill (/design v2.5 exit) and the S2 consumer skill
# (/build entry) invoke `bash scripts/validate-design-spec.sh`. Without
# this binding the validator can be silently disconnected — D9's drift-
# fails proof revealed that on first build (commenting out /design's
# call produced 0 contract-test failures despite the D4 invariant being
# broken). This is the analog of S9-1 for the validator-binding contract.
#
# Looks for the invocation inside any fenced ```bash code block in the
# canonical skill files.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Require the invocation to be a real bash command line, not a comment.
# Allow leading whitespace; reject leading `#` (commented-out / drift).
INVOCATION_RE='^[[:space:]]*bash scripts/validate-design-spec\.sh'

# Same fenced-bash extractor as S9-1; round-4 P1 #1 indented-fence
# tolerance applies here too.
extract_bash_blocks() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { in_block=1; next }
    /^[[:space:]]*```[[:space:]]*$/     { in_block=0; next }
    in_block                             { print }
  ' "$1"
}

failed=0
for skill in design build; do
  skill_path="$ROOT/skills/$skill/SKILL.md"
  if [ ! -f "$skill_path" ]; then
    echo "FAIL: S2-7 — skill not found: skills/$skill/SKILL.md" >&2
    failed=1
    continue
  fi
  if ! extract_bash_blocks "$skill_path" | grep -qE "$INVOCATION_RE"; then
    echo "FAIL: S2-7 — skills/$skill/SKILL.md has no '$INVOCATION_RE' invocation in fenced bash blocks" >&2
    echo "       (D4 single-source-of-truth requires this skill to bind to the S2 validator)" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
pass "S2-7"
