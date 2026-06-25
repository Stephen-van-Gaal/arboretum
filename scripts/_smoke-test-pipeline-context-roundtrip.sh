#!/usr/bin/env bash
# owner: pipeline-context-ledger
# scope: plugin-only
# _smoke-test-pipeline-context-roundtrip.sh — Integration: writer → reader hits
# within one HEAD window; misses after HEAD advances (the self-invalidation
# contract that makes the ledger safe to cache across stages, #665).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="$ROOT/scripts/refresh-pipeline-context.sh"
READER="$ROOT/scripts/read-pipeline-context.sh"
for s in "$WRITER" "$READER"; do
  [ -f "$s" ] || { echo "FAIL: $s not found" >&2; exit 1; }
done

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; fail=1; }

REPO="$FIX/repo"; mkdir -p "$REPO/docs" "$FIX/bin"
git -C "$REPO" init -q
git -C "$REPO" config user.email f@e.com
git -C "$REPO" config user.name f
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
printf '## Spec Index\n\n| Spec |\n|---|\n| foo |\n' > "$REPO/docs/REGISTER.md"
printf '#!/usr/bin/env bash\nprintf "{\\"number\\":1,\\"title\\":\\"T\\",\\"body\\":\\"b\\",\\"labels\\":[]}"\n' > "$FIX/bin/gh"
chmod +x "$FIX/bin/gh"

w() { (cd "$REPO" && PATH="$FIX/bin:$PATH" bash "$WRITER" "$@"); }
r() { (cd "$REPO" && bash "$READER" "$@" 2>/dev/null); }

# Seed the ledger at the current HEAD.
w 1 >/dev/null

# Within the same HEAD window: spec_index and issue hit.
if r spec_index | grep -q foo; then pass "fresh window: spec_index served"; else fail_case "spec_index not served on fresh HEAD"; fi
r issue >/dev/null 2>&1 && pass "fresh window: issue served" || fail_case "issue not served on fresh HEAD"

# Advance HEAD (e.g. a /consolidate commit or a /land fix-push): ledger self-invalidates.
git -C "$REPO" commit -q --allow-empty -m advance
r spec_index >/dev/null 2>&1 && fail_case "stale HEAD must miss (self-invalidation broken)" || pass "advanced HEAD: ledger self-invalidates"

# Re-seed at the new HEAD: hits again (read-through repopulation behaviour).
w 1 >/dev/null
r spec_index >/dev/null 2>&1 && pass "re-seed at new HEAD: served again" || fail_case "re-seed did not restore a hit"

if [ "$fail" -ne 0 ]; then echo "pipeline-context roundtrip: FAIL" >&2; exit 1; fi
echo "pipeline-context roundtrip: PASS"
