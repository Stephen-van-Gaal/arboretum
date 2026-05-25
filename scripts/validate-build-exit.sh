#!/usr/bin/env bash
# owner: pipeline-contracts-template
# validate-build-exit.sh — S3 contract enforcement.
#
# Validates a `/build exited` journey-log line and its referenced
# design spec against the S3 contract
# (`docs/contracts/s3-build-to-finish.contract.md`).
#
# Inputs:
#   $1 — path to a file containing the journey-log line (one line)
#   $2 — (optional) path to the related design spec; required when
#        exit-status is escape-hatch (S3-7) or when exit-status is
#        success and plan: is non-null (S3-3 plan-checkbox check)
#
# Output format mirrors validate-design-spec.sh:
#   S3-DRIFT: <N> issue(s) in <log-line-file>
#     - <assertion-id>: <reason>
#
# Exit codes:
#   0 — log line + spec satisfy S3 post-conditions
#   1 — contract violation(s) printed to stderr
#   2 — invocation problem

set -uo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: validate-build-exit.sh <log-line-file> [<design-spec-path>]" >&2
  exit 2
fi

LOG_FILE="$1"
SPEC_PATH="${2:-}"

if [ ! -f "$LOG_FILE" ]; then
  echo "validate-build-exit.sh: log file not found: $LOG_FILE" >&2
  exit 2
fi

ISSUES_FILE=$(mktemp)
trap 'rm -f "$ISSUES_FILE"' EXIT

LOG_LINE=$(head -n1 "$LOG_FILE")

# S3-1: line must include exit-status:
if ! echo "$LOG_LINE" | grep -q "exit-status:"; then
  echo "S3-1: log line missing 'exit-status:' field" >> "$ISSUES_FILE"
fi

# Extract exit-status value (S3-2 enum check). log-stage.sh emits in
# comma-separated KV form (`exit-status: success, plan: ...`), so the
# token boundary is whitespace OR comma — not whitespace alone.
STATUS=$(echo "$LOG_LINE" | sed -nE 's/.*exit-status:[[:space:]]*([^[:space:],]+).*/\1/p')
if [ -z "$STATUS" ]; then
  : # already reported as S3-1
elif [ "$STATUS" != "success" ] && [ "$STATUS" != "escape-hatch" ]; then
  echo "S3-2: exit-status value not in {success, escape-hatch} (got '$STATUS')" >> "$ISSUES_FILE"
fi

# Extract plan path (may be `null`, a path, or empty if omitted from the line).
# Same comma-OR-whitespace boundary as exit-status — log-stage.sh's
# comma-separated KV emission would otherwise include a trailing comma.
PLAN_PATH=$(echo "$LOG_LINE" | sed -nE 's/.*plan:[[:space:]]*([^[:space:],]+).*/\1/p')

# S3-3: success + plan path mode → every checkbox checked or skipped-with-reason
# Round-4 P2 #6 fix: require SPEC_PATH when exit-status=success AND plan is
# non-null. Without the spec arg, we cannot reliably resolve the plan path
# nor verify post-conditions — so a missing spec arg is itself S3-DRIFT.
if [ "$STATUS" = "success" ] && [ -n "$PLAN_PATH" ] && [ "$PLAN_PATH" != "null" ]; then
  if [ -z "$SPEC_PATH" ]; then
    echo "S3-3: success exit with plan: $PLAN_PATH requires a design-spec path argument (post-conditions cannot be verified without it)" >> "$ISSUES_FILE"
  else
    # Resolve plan against repo root (same logic as validate-design-spec.sh)
    spec_dir=$(cd "$(dirname "$SPEC_PATH")" 2>/dev/null && pwd || echo "")
    if [ -z "$spec_dir" ]; then
      echo "S3-3: design spec path not resolvable: $SPEC_PATH" >> "$ISSUES_FILE"
    else
      root="$spec_dir"
      while [ "$root" != "/" ]; do
        if [ -d "$root/.git" ] || [ -f "$root/CLAUDE.md" ]; then
          break
        fi
        root=$(dirname "$root")
      done
      plan_resolved="$root/$PLAN_PATH"
      if [ ! -f "$plan_resolved" ]; then
        echo "S3-3: plan file not found at $PLAN_PATH (resolved: $plan_resolved)" >> "$ISSUES_FILE"
      else
        # Find any unchecked checkboxes without (skipped: ...) marker
        bad=$(grep -nE '^[[:space:]]*- \[ \]' "$plan_resolved" | grep -v '(skipped:' || true)
        if [ -n "$bad" ]; then
          count=$(echo "$bad" | wc -l | tr -d ' ')
          echo "S3-3: $count unchecked plan checkbox(es) without (skipped: <reason>) marker in $PLAN_PATH" >> "$ISSUES_FILE"
        fi
      fi
    fi
  fi
fi

# S3-7: escape-hatch must carry an `escape-hatch:` block in the design spec
if [ "$STATUS" = "escape-hatch" ]; then
  if [ -z "$SPEC_PATH" ]; then
    echo "S3-7: escape-hatch exit requires a design spec path (was not provided)" >> "$ISSUES_FILE"
  elif [ ! -f "$SPEC_PATH" ]; then
    echo "S3-7: design spec not found: $SPEC_PATH" >> "$ISSUES_FILE"
  elif ! grep -q "^escape-hatch:" "$SPEC_PATH"; then
    echo "S3-7: design spec missing 'escape-hatch:' block naming the trigger criterion" >> "$ISSUES_FILE"
  fi
fi

rc=0
if [ -s "$ISSUES_FILE" ]; then
  rc=1
  count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
  echo "S3-DRIFT: $count issue(s) in $LOG_FILE" >&2
  while IFS= read -r line; do
    echo "  - $line" >&2
  done < "$ISSUES_FILE"
fi

exit "$rc"
