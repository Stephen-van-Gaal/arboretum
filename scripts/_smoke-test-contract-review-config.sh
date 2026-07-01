#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Contract smoke: the review: schema shape shared by the three scripts.
# Guards the implicit coupling per CLAUDE.md ## Schema-coupled scripts —
#   read-review-config.sh (producer) ⇄ request-review.sh (consumer key form)
#   collect-review.sh normalized-record key set (consumed by /land + M-C gate)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
note() { echo "FAIL: $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- 1. Producer/consumer key-form coupling ---
cat > "$tmp/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: copilot
      request: ready-for-review
      cadence: auto-flaky
  default_request_policy: complexity-gated
  re_review_condition: substantive-only
YML
cfg="$(cd "$tmp" && bash "$SCRIPT_DIR/read-review-config.sh" 2>/dev/null)"
echo "$cfg" | grep -qE '^ai_reviewer\.copilot\.request=' \
  || note "producer key form 'ai_reviewer.<name>.<field>' drifted in read-review-config.sh"
grep -q 'ai_reviewer\\\.' "$SCRIPT_DIR/request-review.sh" \
  || note "consumer request-review.sh no longer reads the 'ai_reviewer.<name>.<field>' form"

# --- design_doc_policy producer/consumer coupling (#935) ---
cat > "$tmp/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: codex
      request: comment
      cadence: comment-trigger
  design_doc_policy:
    reviewers: [codex]
    bypass_complexity_gate: true
YML
ddpcfg="$(cd "$tmp" && bash "$SCRIPT_DIR/read-review-config.sh" 2>/dev/null)"
echo "$ddpcfg" | grep -qx 'design_doc_policy.reviewers=codex' \
  || note "producer dropped design_doc_policy.reviewers"
grep -q 'design_doc_policy' "$SCRIPT_DIR/request-review.sh" \
  || note "consumer request-review.sh no longer reads design_doc_policy"

# --- 2. Normalized-record key set (collect-review.sh) ---
mkdir -p "$tmp/fix"
echo '[{"id":1,"path":"a","line":2,"user":{"login":"x"},"in_reply_to_id":null,"body":"b"}]' > "$tmp/fix/gh-inline.json"
echo '[]' > "$tmp/fix/gh-reviews.json"
echo '[]' > "$tmp/fix/gh-conversation.json"
echo '{}' > "$tmp/fix/gh-threads.json"
rec="$(cd "$tmp" && COLLECT_FIXTURE_DIR="$tmp/fix" bash "$SCRIPT_DIR/collect-review.sh" 1 2>/dev/null)"
expected='["author","backend","body","file","id","is_outdated","line","priority","reply_handle","status","surface"]'
got="$(echo "$rec" | jq -cS '.[0]|keys')"
[ "$got" = "$expected" ] || note "normalized-record key set drifted: expected $expected, got $got"

[ "$fail" -eq 0 ] && echo "PASS: contract-review-config" || exit 1
