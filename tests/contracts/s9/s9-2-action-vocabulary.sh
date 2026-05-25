#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-2
# pipeline-version: v2
#
# Asserts: every action in any stage-skill's log-stage.sh callsite
# uses one of the seven-entry vocabulary (CWD-2). The action is the
# THIRD positional argument: `bash scripts/log-stage.sh <ISSUE>
# <STAGE> <ACTION> [kv-pairs...]`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

CANONICAL_STAGES="start design build finish pr land cleanup reflect handoff"
ACTIONS="entered exited skipped re-entered summary repair dispatched"

failed=0
for stage in $CANONICAL_STAGES; do
  skill="$ROOT/skills/$stage/SKILL.md"
  [ -f "$skill" ] || continue

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    args_part=${line#*log-stage.sh }
    # shellcheck disable=SC2206
    args=( $args_part )
    if [ "${#args[@]}" -lt 3 ]; then
      echo "FAIL: S9-2 — skills/$stage/SKILL.md log-stage.sh callsite has <3 positional args: $line" >&2
      failed=1
      continue
    fi
    a="${args[2]}"
    a="${a%;}"
    a="${a%\"}"
    a="${a#\"}"
    valid=0
    for v in $ACTIONS; do
      [ "$a" = "$v" ] && valid=1 && break
    done
    if [ "$valid" -eq 0 ]; then
      echo "FAIL: S9-2 — skills/$stage/SKILL.md uses action '$a' (3rd positional) not in seven-entry vocabulary" >&2
      failed=1
    fi
  done < <(grep -E 'bash scripts/log-stage\.sh' "$skill")
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
pass "S9-2"
