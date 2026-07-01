#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Integration: the design-doc review path end to end (config -> request-review),
# plus the docs-only classifier on a shaping design spec. No network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
note() { echo "FAIL: $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1) A shaping design-spec-only change classifies as docs-config.
printf '%s\n' "docs/superpowers/specs/2026-06-28-example-design.md" \
  | bash "$SCRIPT_DIR/classify-pr-change.sh" --files-from - | grep -qx 'docs-config' \
  || note "a design-doc-only diff did not classify as docs-config"

# 2) Config -> request-review subset resolves to Codex only.
cat > "$tmp/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: copilot
      request: ready-for-review
      cadence: auto-flaky
    - name: codex
      request: comment
      cadence: comment-trigger
  design_doc_policy:
    reviewers: [codex]
    bypass_complexity_gate: true
YML
out="$(cd "$tmp" && REVIEW_DRY_RUN=1 bash "$SCRIPT_DIR/request-review.sh" 7 --design-doc 2>/dev/null)"
echo "$out" | grep -qi 'codex'   || note "integration: codex not requested on design-doc path"
echo "$out" | grep -qi 'copilot' && note "integration: copilot leaked onto design-doc path"

[ "$fail" -eq 0 ] && echo "PASS: design-doc-review-integration" || exit 1
