#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-statusline.sh — Contract test for
# docs/contracts/statusline.contract.md. Asserts STL-1..STL-3 against
# .claude/hooks/statusline.sh by driving the real hook with a stdin
# session payload in a git fixture and asserting on its single-line
# stdout.
#
# Reuses the fixture shape from _smoke-test-statusline.sh: minimal git
# repo, copied hook, no-op refresh-stage-cache stub so a pre-seeded chip
# cache survives. Picked up automatically by ci-checks.sh's smoke loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/statusline.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; fail=1; }

new_fixture() {
  local fix="$ROOT_TMP/$1"
  mkdir -p "$fix/.claude/hooks" "$fix/scripts" "$fix/.arboretum"
  cp "$HOOK" "$fix/.claude/hooks/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-stage-cache.sh"
  chmod +x "$fix/scripts/refresh-stage-cache.sh"
  git -C "$fix" init -q
  git -C "$fix" config user.email f@e.com; git -C "$fix" config user.name f
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m seed
  echo "$fix"
}

run_hook() { printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/statusline.sh"; }

PAYLOAD='{"model":{"display_name":"Opus 4.7"},"workspace":{"project_dir":"__FIX__"},"context_window":{"used_percentage":10}}'

# ── STL-1: chip present when stage cache has issue + stage ──────────────
fix=$(new_fixture stl1)
cat > "$fix/.arboretum/active-stage-cache.json" <<'JSON'
{ "issue": 307, "stage": "/build", "ts": "2026-05-23T14:05:00Z" }
JSON
out=$(run_hook "$fix" "${PAYLOAD//__FIX__/$fix}")
echo "$out" | grep -q '\[#307 /build\]' \
  && pass STL-1 || fail_case STL-1 "expected chip [#307 /build]" "$out"

# ── STL-2: chip absent when no cache; line still renders, exit 0 ────────
fix=$(new_fixture stl2)
out=$(run_hook "$fix" "${PAYLOAD//__FIX__/$fix}"); rc=$?
if echo "$out" | grep -q '\[#'; then
  fail_case STL-2 "chip rendered without a cache" "$out"
elif [ "$rc" = 0 ] && echo "$out" | grep -q 'ctx 10%'; then
  pass STL-2
else
  fail_case STL-2 "rc=$rc or rest-of-line missing" "$out"
fi

# ── STL-3: consumer re-scrub of the stage field ─────────────────────────
# Seed a stage value carrying a raw ESC (0x1b) byte (written via python3 so
# a real control byte lands in the JSON), then confirm the rendered chip
# has the ESC stripped (printable residue preserved).
fix=$(new_fixture stl3)
python3 -c "
import json
print(json.dumps({'issue': 99, 'stage': '/bu\x1b[31mild', 'ts': '2026-05-23T14:05:00Z'}))
" > "$fix/.arboretum/active-stage-cache.json"
out=$(run_hook "$fix" "${PAYLOAD//__FIX__/$fix}")
if ! echo "$out" | grep -q '\[#99'; then
  fail_case STL-3 "chip [#99 …] absent" "$out"
elif printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  fail_case STL-3 "raw ESC (0x1b) survived into chip (consumer re-scrub failed)" "$out"
elif echo "$out" | grep -q '/bu\[31mild'; then
  pass STL-3   # ESC stripped, printable residue preserved
else
  fail_case STL-3 "scrubbed stage residue not as expected" "$out"
fi

[ "$fail" = 0 ] && echo "statusline contract: ALL PASS" || exit 1
