#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-session-start-banner.sh — Contract test for
# docs/contracts/session-start-banner.contract.md. Asserts SSB-1..SSB-4
# against .claude/hooks/session-start.sh by driving the real hook in a
# git fixture and asserting on its stdout (the SessionStart
# additionalContext banner).
#
# Reuses the fixture shape from _smoke-test-pipeline-state-banner.sh:
# minimal git repo, governed-doc stubs, copied hook, no-op refresh stubs
# so cache files we pre-seed survive (the refresh scripts don't overwrite
# them). Picked up automatically by ci-checks.sh's smoke-test loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; fail=1; }

new_fixture() {
  local fix="$ROOT_TMP/$1"
  mkdir -p "$fix/docs/definitions" "$fix/.claude/hooks" "$fix/scripts/roadmap" "$fix/.arboretum"
  echo "# x" > "$fix/docs/ARCHITECTURE.md"
  echo "# x" > "$fix/docs/REGISTER.md"
  echo "# x" > "$fix/contracts.yaml"
  echo "layer: 0" > "$fix/.arboretum.yml"
  cp "$HOOK" "$fix/.claude/hooks/"
  # No-op refresh stubs so pre-seeded caches survive the boot refresh.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-next-cache.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-stage-cache.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-workspace-cache.sh"
  chmod +x "$fix/scripts/"*.sh
  git -C "$fix" init -q
  git -C "$fix" config user.email f@e.com; git -C "$fix" config user.name f
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m seed
  echo "$fix"
}

run_hook() { CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/session-start.sh" 2>&1; }

# ── SSB-1: pipeline-state block present with cache, absent without ──────
fix=$(new_fixture ssb1)
cat > "$fix/.arboretum/active-stage-cache.json" <<'JSON'
{ "issue": 307, "stage": "/build", "ts": "2026-05-23T14:05:00Z" }
JSON
cat > "$fix/.arboretum/log-comments-cache.json" <<'JSON'
[
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-22T17:20:00Z — /design exited, plan: docs/plan.md, next: /build", "createdAt":"2026-05-22T17:20:00Z"},
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-22T17:35:00Z — /handoff summary, summary: \"Drafted WS9 plan; ready for build\"", "createdAt":"2026-05-22T17:35:00Z"}
]
JSON
out=$(run_hook "$fix")
if echo "$out" | grep -qE 'Stage:.*/build' \
   && echo "$out" | grep -qE 'Last action:.*/design exited' \
   && echo "$out" | grep -qE 'Last session:.*WS9 plan'; then
  fix2=$(new_fixture ssb1b)
  out2=$(run_hook "$fix2")
  if echo "$out2" | grep -qE '^Stage:'; then
    fail_case SSB-1 "Stage: line rendered with no stage cache"
  else
    pass SSB-1
  fi
else
  fail_case SSB-1 "expected Stage/Last action/Last session lines" "$out"
fi

# ── SSB-2: scrub invariant on the [Next-up] block ───────────────────────
# Seed next-cache.json with a title carrying a raw ESC (0x1b) byte (written
# via python3 so a real control byte lands in the JSON string), then confirm
# the rendered [Next-up] block has the ESC byte stripped by the hook's scrub.
fix=$(new_fixture ssb2)
python3 -c "
import json
d = {
  'fetched_at': '2026-05-23T14:00:00Z',
  'issue': {'number': 42, 'title': 'evil\x1b[31mTITLE', 'url': 'u',
            'body_first_lines': [], 'body_empty': False,
            'labels': ['next-up'], 'updated_at': '2026-05-23T14:00:00Z'},
  'handoff': None, 'no_gh_remote': False, 'error': None
}
print(json.dumps(d))
" > "$fix/.arboretum/next-cache.json"
out=$(run_hook "$fix")
if ! echo "$out" | grep -q '\[Next-up\] #42'; then
  fail_case SSB-2 "[Next-up] #42 block absent" "$out"
elif printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  fail_case SSB-2 "raw ESC (0x1b) survived into [Next-up] block (consumer re-scrub failed)" "$out"
elif echo "$out" | grep -q 'evil\[31mTITLE'; then
  pass SSB-2   # ESC stripped, printable residue preserved
else
  fail_case SSB-2 "scrubbed title residue not as expected" "$out"
fi

# ── SSB-3: roadmap orientation passthrough is appended (and NOT scrubbed) ─
# Stub render-run.sh --condensed to emit a [roadmap] block whose content
# carries a raw ESC byte. The contract documents that this passthrough is
# NOT control-char scrubbed by the hook (known gap). We assert the block is
# appended verbatim — including the ESC byte — which documents the gap
# behaviourally without claiming the lack of scrub is desirable.
fix=$(new_fixture ssb3)
cat > "$fix/scripts/roadmap/render-run.sh" <<'SH'
#!/usr/bin/env bash
printf '[roadmap] evil\033INJECT block\n'
SH
chmod +x "$fix/scripts/roadmap/render-run.sh"
out=$(run_hook "$fix")
if ! echo "$out" | grep -q '\[roadmap\]'; then
  fail_case SSB-3 "[roadmap] passthrough block not appended" "$out"
elif printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  pass SSB-3   # ESC byte present → confirms the documented unscrubbed-passthrough gap
else
  fail_case SSB-3 "expected unscrubbed roadmap passthrough (ESC byte) — gap may have been silently closed; update the contract if so" "$out"
fi

# ── SSB-4: always-exits-0 on a clean no-signal fixture ──────────────────
fix=$(new_fixture ssb4)
CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && pass SSB-4 || fail_case SSB-4 "hook exited $rc on clean fixture"

[ "$fail" = 0 ] && echo "session-start-banner contract: ALL PASS" || exit 1
