#!/usr/bin/env bash
# owner: shared-components
# scope: plugin-only
# ci-parallel: safe
# ci-tier: balanced
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/lib/owner-doc-resolve.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/docs/specs" "$tmp/docs/groups"
: > "$tmp/docs/specs/alpha.spec.md"
: > "$tmp/docs/groups/beta.md"

fail=0
# spec resolves
[ "$(owner_doc_path alpha "$tmp")" = "$tmp/docs/specs/alpha.spec.md" ] || { echo "FAIL: spec resolve"; fail=1; }
# group resolves (D7)
[ "$(owner_doc_path beta "$tmp")" = "$tmp/docs/groups/beta.md" ] || { echo "FAIL: group resolve"; fail=1; }
# spec wins when both exist (spec precedence)
: > "$tmp/docs/groups/alpha.md"
[ "$(owner_doc_path alpha "$tmp")" = "$tmp/docs/specs/alpha.spec.md" ] || { echo "FAIL: spec should win over group"; fail=1; }
# missing returns 1, empty stdout
if owner_doc_path ghost "$tmp" >/dev/null; then echo "FAIL: ghost should be unresolved"; fail=1; fi
[ -z "$(owner_doc_path ghost "$tmp" 2>/dev/null || true)" ] || { echo "FAIL: ghost should echo nothing"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: owner-doc-resolve" || exit 1
