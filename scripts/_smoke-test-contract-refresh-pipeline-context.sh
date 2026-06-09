#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-refresh-pipeline-context.sh — Contract test for
# docs/contracts/refresh-pipeline-context.contract.md: the produced cache
# carries exactly the documented top-level key set (#665).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="$ROOT/scripts/refresh-pipeline-context.sh"
[ -f "$WRITER" ] || { echo "FAIL: $WRITER not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

REPO="$FIX/repo"; mkdir -p "$REPO/docs" "$FIX/bin"
git -C "$REPO" init -q
git -C "$REPO" config user.email f@e.com
git -C "$REPO" config user.name f
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
printf '## Spec Index\n\n| Spec |\n|---|\n| foo |\n' > "$REPO/docs/REGISTER.md"
printf '#!/usr/bin/env bash\nprintf "{}"\n' > "$FIX/bin/gh"; chmod +x "$FIX/bin/gh"

(cd "$REPO" && PATH="$FIX/bin:$PATH" bash "$WRITER" 1 >/dev/null)
cache="$REPO/.arboretum/pipeline-context-cache.json"

# Use sorted `keys` (not keys_unsorted): the contract specifies the key *set*,
# so the test must not couple to JSON insertion order (#697 review).
keys="$(jq -r 'keys | join(",")' "$cache")"
want="base_ref,changed_files,diff_stat,head_sha,issue,spec_index,written_at"
if [ "$keys" = "$want" ]; then
  echo "refresh-pipeline-context contract: PASS"
else
  echo "FAIL: cache key set drift" >&2
  echo "  got:  $keys" >&2
  echo "  want: $want" >&2
  exit 1
fi
