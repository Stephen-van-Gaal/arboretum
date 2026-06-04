#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-1
# pipeline-version: unified
#
# Asserts: every stage skill in the canonical set invokes
# `bash scripts/log-stage.sh` on entry and on exit.
#
# Round-4 P1 #1 fix: bash-fence extractor allows indented fences
# (common in markdown nested lists).
# Round-4 P1 #5 fix: counting `count >= 2` isn't enough — the contract
# is specifically that `entered` AND `exited` actions both appear at
# least once each, not just any two invocations (e.g. summary,summary
# would otherwise pass).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

CANONICAL_STAGES="start design build finish pr land cleanup reflect handoff"
INVOCATION_RE='bash scripts/log-stage\.sh'

# Extract content from fenced ```bash ... ``` blocks. Round-4 P1 #1:
# allow optional leading whitespace before the fence (markdown lists
# indent code blocks). Closing fence matches any ``` at the same
# leading whitespace level.
extract_bash_blocks() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { in_block=1; next }
    /^[[:space:]]*```[[:space:]]*$/     { in_block=0; next }
    in_block                             { print }
  ' "$1"
}

failed=0
for stage in $CANONICAL_STAGES; do
  skill="$ROOT/skills/$stage/SKILL.md"
  if [ ! -f "$skill" ]; then
    echo "FAIL: S9-1 — skill not found: skills/$stage/SKILL.md" >&2
    failed=1
    continue
  fi
  blocks=$(extract_bash_blocks "$skill")
  if [ -z "$blocks" ]; then
    echo "FAIL: S9-1 — skills/$stage/SKILL.md has no fenced \`\`\`bash blocks" >&2
    failed=1
    continue
  fi

  # Find every line invoking log-stage.sh (inside bash blocks only).
  invocations=$(echo "$blocks" | grep -E "$INVOCATION_RE" || true)
  if [ -z "$invocations" ]; then
    echo "FAIL: S9-1 — skills/$stage/SKILL.md has no log-stage.sh invocations in bash blocks" >&2
    failed=1
    continue
  fi

  # Round-4 P1 #5: extract the 3rd positional arg (the action) from each
  # invocation; assert `entered` and `exited` both appear.
  has_entered=0
  has_exited=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    args_part=${line#*log-stage.sh }
    # shellcheck disable=SC2206
    args=( $args_part )
    if [ "${#args[@]}" -lt 3 ]; then
      continue
    fi
    a="${args[2]}"
    a="${a%;}"
    a="${a%\"}"
    a="${a#\"}"
    case "$a" in
      entered) has_entered=1 ;;
      exited)  has_exited=1 ;;
    esac
  done <<< "$invocations"

  if [ "$has_entered" -eq 0 ]; then
    echo "FAIL: S9-1 — skills/$stage/SKILL.md missing log-stage.sh invocation with action=entered" >&2
    failed=1
  fi
  if [ "$has_exited" -eq 0 ]; then
    echo "FAIL: S9-1 — skills/$stage/SKILL.md missing log-stage.sh invocation with action=exited" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
pass "S9-1"
