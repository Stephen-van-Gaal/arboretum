#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-read-pipeline-context.sh — Contract test for
# docs/contracts/read-pipeline-context.contract.md: the field vocabulary is
# exactly {issue, spec_index, changed_files, diff_stat} and the SHA-freshness
# gate holds (#665).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT/scripts/read-pipeline-context.sh"
[ -f "$READER" ] || { echo "FAIL: $READER not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0

REPO="$FIX/repo"; mkdir -p "$REPO/.arboretum"
git -C "$REPO" init -q
git -C "$REPO" config user.email f@e.com
git -C "$REPO" config user.name f
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
sha="$(git -C "$REPO" rev-parse HEAD)"
# Non-empty fields: an empty field is now a deliberate MISS (#697 review), so the
# vocabulary assertion below uses non-empty values to test the hit path.
printf '{"head_sha":"%s","issue":{"number":1},"spec_index":"s","changed_files":["x"],"diff_stat":"d"}\n' "$sha" \
  > "$REPO/.arboretum/pipeline-context-cache.json"

r() { (cd "$REPO" && bash "$READER" "$1" 2>/dev/null); }

for f in issue spec_index changed_files diff_stat; do
  r "$f" >/dev/null 2>&1 || { echo "FAIL: documented field '$f' should hit on fresh SHA" >&2; fail=1; }
done
r unknown >/dev/null 2>&1 && { echo "FAIL: undocumented field 'unknown' should miss" >&2; fail=1; }

# Freshness gate: advance HEAD → every field misses.
git -C "$REPO" commit -q --allow-empty -m next
r issue >/dev/null 2>&1 && { echo "FAIL: stale SHA should gate all reads" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then echo "read-pipeline-context contract: FAIL" >&2; exit 1; fi
echo "read-pipeline-context contract: PASS"
