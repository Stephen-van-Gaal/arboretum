#!/usr/bin/env bash
# owner: session-start-cycle-state
# _smoke-test-workspace-banner.sh — Integration assertions for the
# [Workspace] banner block rendered by .claude/hooks/session-start.sh.
#
# Covers contract clause RWC-8 (consumer obligation): the renderer must
# apply the routing precedence correctly, enforce the silence rule, and
# re-scrub author-controlled string fields before output.
#
# Each case:
#   1. Builds a minimal git fixture.
#   2. Copies the real session-start.sh hook into the fixture.
#   3. Drops a NO-OP refresh-workspace-cache.sh stub (executable, exits 0,
#      does NOT touch the cache) so the render block executes while leaving
#      the pre-seeded workspace-cache.json intact.
#   4. Pre-seeds .arboretum/workspace-cache.json with the exact shape
#      under test.
#   5. Optionally pre-seeds .arboretum/next-cache.json for mode-B cases.
#   6. Runs the hook and asserts on stdout.
#
# Cases:
#   1.  dirty → mode A  (Resume WIP)
#   2.  behind-main clean on main → mode D  (Sync before branching)
#   3.  clean main, zero signal → SILENCE  (no [Workspace] block)
#   4.  clean feature branch, no other signal → header only, no action line
#   5.  recorded next-up branch present AND main behind → mode B (resume), NOT D
#   6.  recorded branch absent from local_branches/worktrees → fresh-branch msg
#   7.  detached HEAD (current_branch:null) → checkout message
#   8.  unknown drift (main:null) on main → SILENCE  (no "(current ✓)" possible)
#   9.  main ahead (main.ahead:2) → "2 unpushed" in header
#  10.  main.fresh:false with behind:0 (stale refs) → NO "(current ✓)"
#  11.  clean feature branch AND main behind → "git checkout main" action
#  12.  degraded cache (error:"python3-unavailable") → NO [Workspace] block
#  13.  control char in current_upstream.name → stripped in output (RWC-8 re-scrub)
#
# Usage: bash scripts/_smoke-test-workspace-banner.sh
# Exit 0 if all cases pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- actual hook output -----" >&2; printf '%s\n' "$2" >&2; }
  exit 1
}

ok() { echo "PASS: $1"; }

# ── Helper: build a minimal git fixture ──────────────────────────────
# Sets up the bare minimum the hook needs: git repo, governed docs,
# .arboretum.yml, copied hook, and a NO-OP workspace-refresh stub.
# Other refresh scripts (next, stage, update) are absent — the hook
# guards all of them with [ -f "..." ] so absent = skipped.

new_fixture() {
  local name="$1"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/docs/definitions" "$fix/.claude/hooks" \
           "$fix/scripts" "$fix/.arboretum"
  echo "# fixture" > "$fix/docs/ARCHITECTURE.md"
  echo "# fixture" > "$fix/docs/REGISTER.md"
  echo "# fixture" > "$fix/contracts.yaml"
  echo "layer: 0" > "$fix/.arboretum.yml"

  # Copy the real hook so we exercise the current repository code.
  cp "$HOOK" "$fix/.claude/hooks/session-start.sh"
  mkdir -p "$fix/scripts/lib"; cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"

  # NO-OP workspace-refresh stub: makes the guard `[ -f "$WORKSPACE_REFRESH" ]`
  # true so the render block executes, but does NOT overwrite the pre-seeded
  # workspace-cache.json with the fixture repo's actual git state.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-workspace-cache.sh"
  chmod +x "$fix/scripts/refresh-workspace-cache.sh"

  # git init so git-author-count and branch detection don't abort under set -e.
  git -C "$fix" init -q
  git -C "$fix" config user.email "fixture@example.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m "fixture seed" >/dev/null 2>&1

  echo "$fix"
}

run_hook() {
  local fix="$1"
  ( CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" 2>&1 )
}

# Minimal valid workspace-cache template. Callers override specific fields via
# a heredoc written to $fix/.arboretum/workspace-cache.json AFTER this helper.
# (Not a shell function — each case writes its own JSON directly.)

NOW="2026-05-29T10:00:00Z"

# ── Case 1: dirty → mode A (Resume WIP) ──────────────────────────────

case1() {
  local fix; fix=$(new_fixture case1)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "feat/x",
  "dirty": true,
  "dirty_count": 3,
  "main": {"behind": 0, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["feat/x", "main"],
  "open_pr": null,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case1: [Workspace] block absent" "$out"
  echo "$out" | grep -q "Resume WIP here" \
    || fail "case1: expected 'Resume WIP here' action line" "$out"
  ok "case1: dirty → mode A (Resume WIP here)"
}

# ── Case 2: behind-main clean on main → mode D ───────────────────────

case2() {
  local fix; fix=$(new_fixture case2)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 5, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  # No next-cache → no next-up signal.
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case2: [Workspace] block absent" "$out"
  echo "$out" | grep -q "Sync before branching" \
    || fail "case2: expected 'Sync before branching' action" "$out"
  ok "case2: behind-main clean on main → mode D (Sync before branching)"
}

# ── Case 3: clean main, zero signal → SILENCE ────────────────────────

case3() {
  local fix; fix=$(new_fixture case3)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 0, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  # No next-cache → no next-up signal. Silence rule must fire.
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q "\[Workspace\]"; then
    fail "case3: [Workspace] block must be silent on clean main with zero signal" "$out"
  fi
  ok "case3: clean main, zero signal → SILENCE (no [Workspace] block)"
}

# ── Case 4: clean feature branch, no other signal → header only ──────

case4() {
  local fix; fix=$(new_fixture case4)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "feat/x",
  "dirty": false,
  "dirty_count": 0,
  "main": null,
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["feat/x", "main"],
  "open_pr": null,
  "error": null
}
JSON
  # No next-cache → no action line expected.
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\] feat/x" \
    || fail "case4: expected '[Workspace] feat/x' header" "$out"
  # The block must have no action line: no '  → ' immediately after [Workspace].
  # Extract just the Workspace block lines and confirm no arrow.
  if echo "$out" | grep -A1 "\[Workspace\]" | grep -q "^  →"; then
    fail "case4: action line present but none expected (clean feature branch, no signal)" "$out"
  fi
  ok "case4: clean feature branch, no signal → header only, no action line"
}

# ── Case 5: B-resume takes precedence over D (main behind) ───────────

case5() {
  local fix; fix=$(new_fixture case5)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 4, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main", "feat/rec"],
  "open_pr": null,
  "error": null
}
JSON
  # next-cache records feat/rec as the handoff branch.
  cat > "$fix/.arboretum/next-cache.json" <<'JSON'
{
  "fetched_at": "2026-05-29T09:00:00Z",
  "issue": {"number": 7, "title": "Do the thing", "url": "u",
            "body_first_lines": [], "body_empty": false,
            "labels": ["next-up"], "updated_at": "2026-05-29T09:00:00Z"},
  "handoff": {"branch": "feat/rec"},
  "no_gh_remote": false,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case5: [Workspace] block absent" "$out"
  echo "$out" | grep -q "(resume)" \
    || fail "case5: expected '(resume)' in mode-B action line" "$out"
  if echo "$out" | grep -q "Sync before branching"; then
    fail "case5: mode D fired despite recorded branch existing (precedence regression)" "$out"
  fi
  ok "case5: B-resume takes precedence over D when recorded branch exists"
}

# ── Case 6: recorded branch absent → fresh-branch message ────────────

case6() {
  local fix; fix=$(new_fixture case6)
  # feat/rec NOT in local_branches — branch was deleted after /handoff.
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 0, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  cat > "$fix/.arboretum/next-cache.json" <<'JSON'
{
  "fetched_at": "2026-05-29T09:00:00Z",
  "issue": {"number": 7, "title": "Do the thing", "url": "u",
            "body_first_lines": [], "body_empty": false,
            "labels": ["next-up"], "updated_at": "2026-05-29T09:00:00Z"},
  "handoff": {"branch": "feat/rec"},
  "no_gh_remote": false,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case6: [Workspace] block absent" "$out"
  echo "$out" | grep -q "no longer exists" \
    || fail "case6: expected 'no longer exists' fresh-branch message" "$out"
  ok "case6: recorded branch absent → fresh-branch message (no longer exists)"
}

# ── Case 7: detached HEAD (current_branch:null) → checkout message ───

case7() {
  local fix; fix=$(new_fixture case7)
  # current_branch:null signals detached HEAD. error must be null so the
  # renderer does not exit early on the error guard.
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "unknown",
  "current_branch": null,
  "dirty": false,
  "dirty_count": 0,
  "main": null,
  "current_upstream": null,
  "worktrees": [],
  "local_branches": [],
  "open_pr": null,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case7: [Workspace] block absent" "$out"
  echo "$out" | grep -q "Detached HEAD" \
    || fail "case7: expected 'Detached HEAD' checkout message" "$out"
  ok "case7: detached HEAD (current_branch:null) → Detached HEAD checkout message"
}

# ── Case 8: main:null on main → SILENCE (drift unknown, no signal) ───
#
# With main:null: mb=None (falsy), ma=None (falsy). on_feature=false.
# action=None (no mb, no pr, no next_num). has_signal=false → silent.
# Key invariant: "(current ✓)" is never emitted when drift is unknown.
# This is enforced by the block being entirely silent — there's no output
# to misread. If signal somehow fires, it must NOT contain "(current ✓)".

case8() {
  local fix; fix=$(new_fixture case8)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": null,
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  # No next-cache.
  local out; out=$(run_hook "$fix")
  # Primary assertion: block is silent (no [Workspace] emitted).
  if echo "$out" | grep -q "\[Workspace\]"; then
    # If a block DID render, the secondary invariant must hold: no "(current ✓)".
    if echo "$out" | grep -q "(current ✓)"; then
      fail "case8: '(current ✓)' emitted when drift is unknown (main:null)" "$out"
    fi
    fail "case8: [Workspace] block emitted on main with main:null and zero signal (should be silent)" "$out"
  fi
  ok "case8: main:null on main → SILENCE (drift unknown, no false '(current ✓)')"
}

# ── Case 9: main ahead → "2 unpushed" in header ──────────────────────

case9() {
  local fix; fix=$(new_fixture case9)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 0, "ahead": 2, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case9: [Workspace] block absent" "$out"
  echo "$out" | grep -q "2 unpushed" \
    || fail "case9: expected 'main 2 unpushed ⚠' in header" "$out"
  ok "case9: main ahead (ahead:2) → '2 unpushed' in header"
}

# ── Case 10: main.fresh:false, behind:0 → NO "(current ✓)" ──────────

case10() {
  local fix; fix=$(new_fixture case10)
  # fetch_ok:false + fresh:false → "remote unreachable" renders, but
  # "(current ✓)" must never appear because freshness is unconfirmed.
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": false,
  "provider": "github",
  "current_branch": "main",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 0, "ahead": 0, "fresh": false},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["main"],
  "open_pr": null,
  "error": null
}
JSON
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case10: [Workspace] block absent (expected 'remote unreachable' signal)" "$out"
  if echo "$out" | grep -q "(current ✓)"; then
    fail "case10: '(current ✓)' emitted when main.fresh:false (stale refs)" "$out"
  fi
  echo "$out" | grep -q "remote unreachable" \
    || fail "case10: expected 'remote unreachable — staleness unknown' segment" "$out"
  ok "case10: main.fresh:false → NO '(current ✓)', 'remote unreachable' shown"
}

# ── Case 11: clean feature branch AND main behind → git checkout main ─

case11() {
  local fix; fix=$(new_fixture case11)
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": true,
  "provider": "github",
  "current_branch": "feat/x",
  "dirty": false,
  "dirty_count": 0,
  "main": {"behind": 3, "ahead": 0, "fresh": true},
  "current_upstream": null,
  "worktrees": [],
  "local_branches": ["feat/x", "main"],
  "open_pr": null,
  "error": null
}
JSON
  # No next-cache → no recorded branch, no next-up number.
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case11: [Workspace] block absent" "$out"
  echo "$out" | grep -q "git checkout main" \
    || fail "case11: expected 'git checkout main' in action (not bare git pull --ff-only)" "$out"
  ok "case11: clean feat branch + main behind → 'git checkout main && git pull --ff-only' action"
}

# ── Case 12: degraded cache (error set) → NO [Workspace] block ───────

case12() {
  local fix; fix=$(new_fixture case12)
  # error field non-null → renderer exits 0 immediately, block silent.
  cat > "$fix/.arboretum/workspace-cache.json" <<JSON
{
  "fetched_at": "$NOW",
  "fetch_ok": false,
  "provider": "unknown",
  "current_branch": null,
  "dirty": false,
  "dirty_count": 0,
  "main": null,
  "current_upstream": null,
  "worktrees": [],
  "local_branches": [],
  "open_pr": null,
  "error": "python3-unavailable"
}
JSON
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q "\[Workspace\]"; then
    fail "case12: [Workspace] block emitted for degraded cache (error:'python3-unavailable')" "$out"
  fi
  ok "case12: degraded cache (error set) → NO [Workspace] block (never false detached-HEAD)"
}

# ── Case 13: control char in current_upstream.name → stripped ─────────
#
# Field chosen: current_upstream.name — this is the field rendered in the
# "branch N behind <name>" header segment when up.behind > 0 AND branch != "main".
# We seed an ESC byte (0x1b) inside the name and confirm the rendered output
# does not contain the raw byte. The segment looks like:
#   [Workspace] feat/x · branch 1 behind evil<ESC>name
# After re-scrub the ESC must be stripped to:
#   [Workspace] feat/x · branch 1 behind evilname
#
# The ESC byte cannot be placed as a raw byte in a JSON string (Python json
# rejects unescaped control chars). Instead we use python3 to write the JSON
# with the Unicode escape , which decodes to the ESC byte in memory and
# is a valid JSON encoding — mimicking an attacker-controlled upstream name
# stored via the producer's own json.dumps path.

case13() {
  local fix; fix=$(new_fixture case13)
  # Use python3 to write JSON with  in the upstream name field.
  python3 -c "
import json
d = {
  'fetched_at': '${NOW}',
  'fetch_ok': True,
  'provider': 'github',
  'current_branch': 'feat/x',
  'dirty': False,
  'dirty_count': 0,
  'main': {'behind': 0, 'ahead': 0, 'fresh': True},
  'current_upstream': {'name': 'evil\x1bname', 'behind': 1, 'ahead': 0},
  'worktrees': [],
  'local_branches': ['feat/x', 'main'],
  'open_pr': None,
  'error': None
}
print(json.dumps(d, indent=2))
" > "$fix/.arboretum/workspace-cache.json"
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Workspace\]" \
    || fail "case13: [Workspace] block absent (expected branch-upstream segment)" "$out"
  # Assert the raw ESC byte (0x1b) is absent from the rendered output.
  # python3 reads the raw bytes so this works even on macOS where grep -P is absent.
  if printf '%s' "$out" | python3 -c "
import sys
data = sys.stdin.buffer.read()
if b'\x1b' in data:
    sys.exit(1)
sys.exit(0)
"; then
    : # byte absent — good
  else
    fail "case13: raw ESC (0x1b) control byte survived into hook output (RWC-8 re-scrub failed)" "$out"
  fi
  ok "case13: control char in current_upstream.name → stripped by consumer re-scrub (field: current_upstream.name)"
}

# ── Run all cases ─────────────────────────────────────────────────────

case1
case2
case3
case4
case5
case6
case7
case8
case9
case10
case11
case12
case13

echo
echo "All [Workspace] banner integration cases passed."
exit 0
