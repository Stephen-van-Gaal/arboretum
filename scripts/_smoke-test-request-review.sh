#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Smoke test: request-review.sh — backend dispatch + per-reviewer mechanism.
# Uses REVIEW_DRY_RUN=1 so it never touches the network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$SCRIPT_DIR/request-review.sh"
fail=0
note() { echo "FAIL: $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- GitHub backend ---
mkdir -p "$tmp/gh"
cat > "$tmp/gh/.arboretum.yml" <<'YML'
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
  default_request_policy: complexity-gated
  re_review_condition: substantive-only
YML
out="$(cd "$tmp/gh" && REVIEW_DRY_RUN=1 bash "$REQ" 999 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "github dry-run should exit 0 (got $rc)"
echo "$out" | grep -qi "requested: copilot via ready-for-review" || note "copilot initial request missing"
echo "$out" | grep -qi "requested: codex via comment" || note "codex initial request missing"

# --re-request uses the re_request mechanism
out="$(cd "$tmp/gh" && REVIEW_DRY_RUN=1 bash "$REQ" 999 --re-request 2>&1)"
echo "$out" | grep -qi "re-requested: copilot via ready-for-review" || note "copilot re-request missing"
echo "$out" | grep -qi "re-requested: codex via comment" || note "codex re-request missing"

# --reviewer filters to one
out="$(cd "$tmp/gh" && REVIEW_DRY_RUN=1 bash "$REQ" 999 --reviewer codex 2>&1)"
echo "$out" | grep -qi "codex" || note "--reviewer codex produced no codex line"
echo "$out" | grep -qi "copilot" && note "--reviewer codex should not request copilot"

# --reviewer with no value must error out, not hang on a failed shift 2.
out="$(cd "$tmp/gh" && REVIEW_DRY_RUN=1 timeout 5 bash "$REQ" 999 --reviewer 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || note "--reviewer with no value should exit 2 (got $rc — 124 = hang)"
echo "$out" | grep -qi "requires a value" || note "--reviewer with no value should print a usage error"

# A reviewer with no configured mechanism is skipped loudly, never "via ".
mkdir -p "$tmp/nomech"
cat > "$tmp/nomech/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: ghost
      cadence: auto-flaky
  default_request_policy: complexity-gated
  re_review_condition: substantive-only
YML
out="$(cd "$tmp/nomech" && REVIEW_DRY_RUN=1 bash "$REQ" 999 2>&1)"; rc=$?
echo "$out" | grep -qi "ghost.*no .*mechanism" || note "missing-mechanism reviewer should warn and skip"
echo "$out" | grep -qiE "requested: ghost via *$" && note "missing-mechanism reviewer should not print an empty 'via' success"

# --- --design-doc requests only the policy reviewer subset (#935) ---
dd_tmp="$(mktemp -d)"
cat > "$dd_tmp/.arboretum.yml" <<'YML'
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
out="$(cd "$dd_tmp" && REVIEW_DRY_RUN=1 bash "$REQ" 7 --design-doc 2>/dev/null)"
echo "$out" | grep -qi 'codex'   || note "--design-doc did not request codex"
echo "$out" | grep -qi 'copilot' && note "--design-doc must NOT request copilot"
rm -rf "$dd_tmp"

# --- --design-doc with an empty/absent policy requests NOTHING, never all (#935 C2) ---
de_tmp="$(mktemp -d)"
cat > "$de_tmp/.arboretum.yml" <<'YML'
backend: github
review:
  ai_reviewers:
    - name: copilot
      request: ready-for-review
      cadence: auto-flaky
    - name: codex
      request: comment
      cadence: comment-trigger
YML
out="$(cd "$de_tmp" && REVIEW_DRY_RUN=1 bash "$REQ" 7 --design-doc 2>/dev/null)"
echo "$out" | grep -qi 'copilot' && note "--design-doc with empty policy must NOT fall back to copilot"
echo "$out" | grep -qi 'requested:' && note "--design-doc with empty policy should request no reviewers"
rm -rf "$de_tmp"

# --- Azure DevOps backend (AI request stubbed) ---
mkdir -p "$tmp/ado"
cat > "$tmp/ado/.arboretum.yml" <<'YML'
backend: azure-devops
review:
  ai_reviewers:
    - name: copilot
      request: ready-for-review
      cadence: auto-flaky
  default_request_policy: complexity-gated
  re_review_condition: substantive-only
YML
out="$(cd "$tmp/ado" && REVIEW_DRY_RUN=1 bash "$REQ" 42 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "ado should exit 0 (got $rc)"
echo "$out" | grep -qi "stub: ADO" || note "ado should print AI-request stub notice"

[ "$fail" -eq 0 ] && echo "PASS: request-review" || exit 1
