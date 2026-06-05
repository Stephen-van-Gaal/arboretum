#!/usr/bin/env bash
# owner: git-workflow-tooling
# Smoke test: read-review-config.sh — parsing, graceful absence, enum validation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/read-review-config.sh"
fail=0
note() { echo "FAIL: $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fixture 1: full block
cat > "$tmp/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: copilot
      request: ready-for-review
      re_request: ready-for-review
      cadence: auto-flaky
    - name: codex
      request: comment
      re_request: comment
      cadence: comment-trigger
  human_reviewers: []
  default_request_policy: complexity-gated
  re_review_condition: substantive-only
YML
out="$(cd "$tmp" && bash "$READER" 2>/dev/null)"
echo "$out" | grep -qx "ai_reviewer.copilot.cadence=auto-flaky" || note "copilot cadence not parsed"
echo "$out" | grep -qx "ai_reviewer.copilot.request=ready-for-review" || note "copilot request not parsed"
echo "$out" | grep -qx "ai_reviewer.codex.request=comment" || note "codex request not parsed"
echo "$out" | grep -qx "ai_reviewer.codex.cadence=comment-trigger" || note "codex cadence not parsed"
echo "$out" | grep -qx "default_request_policy=complexity-gated" || note "policy not parsed"
echo "$out" | grep -qx "re_review_condition=substantive-only" || note "re_review_condition not parsed"

# Fixture 2: absent block → policy defaults, warn on stderr, exit 0
cat > "$tmp/.arboretum.yml" <<'YML'
backend: github
YML
out="$(cd "$tmp" && bash "$READER" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || note "absent block should exit 0"
echo "$out" | grep -qx "default_request_policy=complexity-gated" || note "absent block missing policy default"
echo "$out" | grep -qx "re_review_condition=substantive-only" || note "absent block missing re_review default"
( cd "$tmp" && bash "$READER" 2>&1 >/dev/null ) | grep -qi "warn" || note "absent block should warn on stderr"

# Fixture 3: invalid enum → exit 1 naming the key
cat > "$tmp/.arboretum.yml" <<'YML'
review:
  re_review_condition: sometimes
YML
err="$( cd "$tmp" && bash "$READER" 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] || note "invalid enum should exit non-zero"
echo "$err" | grep -qi "re_review_condition" || note "invalid enum error should name the key"

# Fixture 4: missing .arboretum.yml → exit 1 (not a crash)
( cd "$tmp" && rm -f .arboretum.yml && bash "$READER" >/dev/null 2>&1 ) && note "missing config should exit non-zero"

[ "$fail" -eq 0 ] && echo "PASS: read-review-config" || exit 1
