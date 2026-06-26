#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-test-metadata.sh — every smoke test must declare # ci-parallel.
# Hard-fail guard: keeps the suite from silently re-bloating with serial tests.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
if bash scripts/audit-test-metadata.sh --check; then
  echo "PASS: all smoke tests declare # ci-parallel"
else
  echo "FAIL: untagged smoke test(s) above — run 'bash scripts/audit-test-metadata.sh --apply'" >&2
  exit 1
fi
