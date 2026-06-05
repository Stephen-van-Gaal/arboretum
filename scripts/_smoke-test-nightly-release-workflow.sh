#!/usr/bin/env bash
# owner: arboretum-as-plugin
# Verify the nightly release-candidate workflow remains a human-merge PR flow.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/nightly-release-candidate.yml"
fail=0

require() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" "$WF"; then
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
require 'RELEASE_CANDIDATE_BASE_SHA=\$\(git rev-parse HEAD\)' "captures preflight base"
require 'GITHUB_ENV' "exports preflight base"
require 'ARBORETUM_CI_MODE: full' "full CI preflight"
require 'bash scripts/ci-checks.sh' "runs ci-checks"
require 'dev-tools/release/update-release-candidate.sh' "calls update helper"

if grep -Eq 'gh pr merge|git tag|sync-public|workflow_dispatch.*sync|gh release create' "$WF"; then
  echo "FAIL: workflow appears to publish, merge, tag, or dispatch public sync" >&2
  fail=1
else
  echo "PASS: workflow does not auto-publish"
fi

exit "$fail"
