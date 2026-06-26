#!/usr/bin/env bash
# owner: pipeline-context-ledger
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-refresh-pipeline-context.sh — Verify refresh-pipeline-context.sh
# writes a well-formed, SHA-stamped, scrubbed pipeline-context cache (#665).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="$ROOT/scripts/refresh-pipeline-context.sh"
[ -f "$WRITER" ] || { echo "FAIL: $WRITER not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# --- hermetic fixture repo -------------------------------------------------
REPO="$FIX/repo"
mkdir -p "$REPO/docs"
git -C "$REPO" init -q
git -C "$REPO" config user.email f@e.com
git -C "$REPO" config user.name f
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
printf '## Spec Index\n\n| Spec | Status |\n|---|---|\n| foo | active |\n' > "$REPO/docs/REGISTER.md"

# Stub gh: emit issue JSON whose body embeds a control char (chr 7), JSON-escaped
# by json.dumps exactly as real `gh issue view --json` would encode it.
BIN="$FIX/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
python3 -c 'import json; print(json.dumps({"number":665,"title":"T","body":"line"+chr(7)+"end","labels":[{"name":"x"}]}))'
GH
chmod +x "$BIN/gh"

out=$(cd "$REPO" && PATH="$BIN:$PATH" bash "$WRITER" 665 2>&1); rc=$?
cache="$REPO/.arboretum/pipeline-context-cache.json"
head_sha=$(git -C "$REPO" rev-parse HEAD)

[ "$rc" -eq 0 ] && pass "exit 0" || fail_case "writer exited $rc" "$out"
[ -f "$cache" ] && pass "cache file written" || fail_case "cache file missing"

if [ -f "$cache" ]; then
  got_sha=$(jq -r '.head_sha' "$cache")
  [ "$got_sha" = "$head_sha" ] && pass "head_sha matches HEAD" || fail_case "head_sha mismatch" "got=$got_sha want=$head_sha"

  [ "$(jq -r '.issue.number' "$cache")" = "665" ] && pass "issue number carried" || fail_case "issue number wrong"

  if jq -e '.spec_index | test("foo")' "$cache" >/dev/null; then pass "spec_index carried"; else fail_case "spec_index missing 'foo'"; fi

  body=$(jq -r '.issue.body' "$cache")
  [ "$body" = "lineend" ] && pass "issue body control-char scrubbed" || fail_case "body not scrubbed" "got=$(printf '%s' "$body" | od -c | head -1)"
fi

if [ "$fail" -ne 0 ]; then echo "refresh-pipeline-context smoke: FAIL" >&2; exit 1; fi
echo "refresh-pipeline-context smoke: PASS"
