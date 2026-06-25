#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
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
  mkdir -p "$fix/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"
  # No-op refresh stubs so pre-seeded caches survive the boot refresh.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-next-cache.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-update-cache.sh"
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
# #763: the issue title/body no longer render into the banner — the only
# author-controlled free text the [Next-up] block now feeds the model is the
# (author-gated) handoff note. Seed next-cache.json with a handoff next_action
# carrying a raw ESC (0x1b) byte (written via python3 so a real control byte
# lands in the JSON string), then confirm the rendered note has the ESC
# stripped by the hook's consumer-side scrub. The bare [Next-up] #42 line must
# also render.
fix=$(new_fixture ssb2)
python3 -c "
import json
d = {
  'fetched_at': '2026-05-23T14:00:00Z',
  'issue': {'number': 42},
  'handoff': {'posted_at': '2026-05-23T14:00:00Z', 'branch': 'feat/x',
              'next_action': 'evil\x1b[31mACTION', 'body': ''},
  'no_gh_remote': False, 'error': None
}
print(json.dumps(d))
" > "$fix/.arboretum/next-cache.json"
out=$(run_hook "$fix")
if ! echo "$out" | grep -qE '^\[Next-up\] #42$'; then
  fail_case SSB-2 "bare [Next-up] #42 line absent" "$out"
elif printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  fail_case SSB-2 "raw ESC (0x1b) survived into handoff note (consumer re-scrub failed)" "$out"
elif echo "$out" | grep -q 'evil\[31mACTION'; then
  pass SSB-2   # ESC stripped from the handoff next_action, printable residue preserved
else
  fail_case SSB-2 "scrubbed handoff-note residue not as expected" "$out"
fi

# ── SSB-8: worktree-map block (worktrees-always #716) ───────────────────
# Seed a workspace cache with ≥2 worktrees (current = feat/716-x) and a sibling
# branch carrying a raw ESC byte. The banner must render a legible map with a
# "you are here" marker on the current worktree, parse the issue number, and
# scrub the author-controlled branch (defense in depth at the render seam).
fix=$(new_fixture ssb6)
python3 -c "
import json
d = {
  'current_branch': 'feat/716-x', 'dirty': False, 'dirty_count': 0,
  'main': {'behind': 0, 'fresh': True}, 'open_pr': {'number': 99, 'title': 'wt'},
  'worktrees': [
    {'path': '/w/main', 'branch': 'main'},
    {'path': '/w/716', 'branch': 'feat/716-x'},
    {'path': '/w/701', 'branch': 'feat/701-y\x1bEVIL'}
  ],
  'local_branches': [], 'fetch_ok': True, 'error': None
}
print(json.dumps(d))
" > "$fix/.arboretum/workspace-cache.json"
out=$(run_hook "$fix")
if ! echo "$out" | grep -q 'you are here'; then
  fail_case SSB-8 "worktree-map 'you are here' marker absent" "$out"
elif printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  fail_case SSB-8 "raw ESC (0x1b) survived into worktree map (render-side scrub failed)" "$out"
elif echo "$out" | grep -q '#716'; then
  pass SSB-8   # marker present, issue parsed, ESC stripped
else
  fail_case SSB-8 "worktree map issue/marker not as expected" "$out"
fi

# ── SSB-4: always-exits-0 on a clean no-signal fixture ──────────────────
fix=$(new_fixture ssb4)
CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && pass SSB-4 || fail_case SSB-4 "hook exited $rc on clean fixture"

# ── SSB-5: update-cache degraded states render diagnostic one-liners ────
fix=$(new_fixture ssb5a)
cat > "$fix/.arboretum/update-cache.json" <<'JSON'
{
  "fetched_at": "2026-06-03T00:00:00Z",
  "installed_version": null,
  "latest_version": null,
  "update_available": false,
  "error": "manifest-not-found"
}
JSON
out=$(run_hook "$fix")
if echo "$out" | grep -qF "[Arboretum] Plugin not found — install with /plugin install arboretum."; then
  pass "SSB-5a"
else
  fail_case "SSB-5a" "missing plugin-not-found diagnostic" "$out"
fi

fix=$(new_fixture ssb5b)
cat > "$fix/.arboretum/update-cache.json" <<'JSON'
{
  "fetched_at": "2026-06-03T00:00:00Z",
  "installed_version": "0.24.6",
  "latest_version": null,
  "update_available": false,
  "error": "gh-call-failed"
}
JSON
out=$(run_hook "$fix")
if echo "$out" | grep -qF "[Arboretum] Could not check latest release — release lookup failed; using installed v0.24.6."; then
  pass "SSB-5b"
else
  fail_case "SSB-5b" "missing release-lookup-failed diagnostic" "$out"
fi

fix=$(new_fixture ssb5c)
printf '{\n  "fetched_at": "2026-06-03T00:00:00Z",\n  "installed_version": "0.24.6\033[31mBAD",\n  "latest_version": null,\n  "update_available": false,\n  "error": "gh-call-failed"\n}\n' > "$fix/.arboretum/update-cache.json"
NOPY_BIN="$ROOT_TMP/no-python-bin"
mkdir -p "$NOPY_BIN"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = python3 ] && continue
    [ -e "$NOPY_BIN/$_b" ] || ln -s "$_f" "$NOPY_BIN/$_b" 2>/dev/null || true
  done
done
out=$(CLAUDE_PROJECT_DIR="$fix" PATH="$NOPY_BIN" bash "$fix/.claude/hooks/session-start.sh" 2>&1)
if printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)"; then
  fail_case "SSB-5c" "raw ESC (0x1b) survived update-cache shell fallback render" "$out"
elif echo "$out" | grep -qF "[Arboretum] Could not check latest release — release lookup failed; using installed v0.24.6[31mBAD."; then
  pass "SSB-5c"
else
  fail_case "SSB-5c" "missing scrubbed fallback diagnostic" "$out"
fi

# ── SSB-7: [Register] mtime-staleness emission removed (#643) ───────────
# The old mtime check emitted "[Register] … may be stale" whenever a spec
# file was newer than REGISTER.md — a false positive on any git checkout /
# stash that bumps mtimes. It was removed in #643. Even under that exact
# triggering condition the banner must NOT emit a [Register] line.
fix=$(new_fixture ssb7)
mkdir -p "$fix/docs/specs"
echo "# spec" > "$fix/docs/specs/x.spec.md"
touch -t 200001010000 "$fix/docs/REGISTER.md"   # force REGISTER older than the spec
out=$(run_hook "$fix")
if echo "$out" | grep -q '\[Register\]'; then
  fail_case SSB-7 "[Register] staleness line emitted — the mtime check should be removed (#643)" "$out"
else
  pass SSB-7
fi

[ "$fail" = 0 ] && echo "session-start-banner contract: ALL PASS" || exit 1
