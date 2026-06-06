#!/usr/bin/env bash
# owner: arboretum-as-plugin
# Verify the nightly release-candidate workflow remains a human-merge PR flow.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/nightly-release-candidate.yml"
fail=0

require() {
  local pattern="$1" label="$2"
  if grep -Eq -- "$pattern" "$WF"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    fail=1
  fi
}

[ -f "$WF" ] || { echo "FAIL: workflow missing: $WF" >&2; exit 1; }

require '^# owner: arboretum-as-plugin$' "owner header"
require 'schedule:' "has nightly schedule"
require 'workflow_dispatch:' "has manual dispatch"
require 'contents: write' "contents write permission"
require 'pull-requests: write' "pull request write permission"
require 'fetch-depth: 0' "full history checkout"
require 'Release preflight' "runs release preflight"
require 'ci-preflight\.sh .*--scope release' "release preflight uses release scope"
require '--repair-commit-mode repair-pr' "release preflight uses repair PR mode"
require 'automation/ci-preflight-repair' "release preflight uses stable repair branch"
require 'RELEASE_CANDIDATE_BASE_SHA=\$\(git rev-parse HEAD\)' "captures preflight base"
require 'GITHUB_ENV' "exports preflight base"
require 'ARBORETUM_CI_PREFLIGHT_DONE: "1"' "full CI skips duplicate preflight"
require 'ARBORETUM_CI_MODE: full' "full CI preflight"
require 'bash scripts/ci-checks.sh' "runs ci-checks"
require 'dev-tools/release/update-release-candidate.sh' "calls update helper"

line_no() {
  local pattern="$1"
  grep -nE -- "$pattern" "$WF" | head -1 | cut -d: -f1 || true
}

if ( set -euo pipefail; line_no '^not present in nightly workflow$' >/dev/null ); then
  echo "PASS: line_no fails soft on missing patterns"
else
  echo "FAIL: line_no should return status 0 with empty output for missing patterns" >&2
  fail=1
fi

preflight_line="$(line_no 'Release preflight')"
ci_line="$(line_no 'bash scripts/ci-checks.sh')"
update_line="$(line_no 'dev-tools/release/update-release-candidate.sh')"
if [ -n "$preflight_line" ] && [ -n "$ci_line" ] && [ "$preflight_line" -lt "$ci_line" ]; then
  echo "PASS: release preflight appears before full CI"
else
  echo "FAIL: release preflight must appear before full CI" >&2
  fail=1
fi

if [ -n "$preflight_line" ] && [ -n "$update_line" ] && [ "$preflight_line" -lt "$update_line" ]; then
  echo "PASS: release preflight appears before update helper"
else
  echo "FAIL: release preflight must appear before update helper" >&2
  fail=1
fi

if grep -Eq 'gh pr merge|git tag|sync-public|workflow_dispatch.*sync|gh release create' "$WF"; then
  echo "FAIL: workflow appears to publish, merge, tag, or dispatch public sync" >&2
  fail=1
else
  echo "PASS: workflow does not auto-publish"
fi

exit "$fail"
