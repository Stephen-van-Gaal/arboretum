#!/usr/bin/env bash
# owner: workflow-unification
# write-agent-brief.sh — Write a minimal agent-target task brief to
# .arboretum/agent-briefs/<issue>.md with the S2 frontmatter shape /build
# enforces. The brief replaces the design spec for agent-target work.
#
# Usage (quoted heredoc — keeps the task statement literal so $/backticks
# in untrusted text are not evaluated by the calling shell):
#   bash scripts/write-agent-brief.sh <issue> <<'EOF'
#   <task statement>
#   EOF
set -euo pipefail

ISSUE="${1:-}"
if [ -z "$ISSUE" ]; then
  echo "write-agent-brief.sh: missing positional <issue> argument" >&2
  echo "usage: bash $0 <issue> <<'EOF'" >&2
  echo "         <task statement>" >&2
  echo "       EOF" >&2
  exit 1
fi

# <issue> must be a strictly positive integer (no leading zeros, no 0).
# read-s2-frontmatter.sh enforces related-issue > 0 downstream; rejecting
# at write time keeps the brief consistent with /build's S2 gate.
case "$ISSUE" in
  ''|*[!0-9]*|0|0[0-9]*)
    echo "write-agent-brief.sh: <issue> must be a strictly positive integer (no 0, no leading zeros), got: $ISSUE" >&2
    exit 1
    ;;
esac

TASK_STATEMENT=$(cat)
if [ -z "$TASK_STATEMENT" ]; then
  echo "write-agent-brief.sh: empty task statement on stdin" >&2
  exit 1
fi

BRIEFS_DIR=".arboretum/agent-briefs"
mkdir -p "$BRIEFS_DIR"
BRIEF="$BRIEFS_DIR/${ISSUE}.md"

# Write the brief in three blocks so the untrusted task statement is
# structurally isolated from any interpolation context. The frontmatter
# heredoc expands only controlled values ($ISSUE is validated numeric;
# $(date) is local). printf writes the task statement literally (no
# expansion of $VAR or $() inside the value). The footer uses a quoted
# heredoc since it contains no variables.

cat > "$BRIEF" <<EOF
---
date: $(date -u +%Y-%m-%d)
related-issue: $ISSUE
triage: agent-target
implementation-mode: direct
plan: null
test-tiers:
  unit: n/a — agent-target work; tests added inline if surface warrants
  contract: n/a — no shared definitions touched
  integration: n/a — no cross-spec dependencies
---

# Agent-target task brief — #$ISSUE

EOF

printf '%s\n' "$TASK_STATEMENT" >> "$BRIEF"

cat >> "$BRIEF" <<'EOF'

> This brief replaces the design spec for agent-target work per WS2 D2.
> If a real design decision surfaces during build, /build's escape hatch
> reclassifies into everything-else and re-enters at SURVEY.
EOF

echo "$BRIEF"
