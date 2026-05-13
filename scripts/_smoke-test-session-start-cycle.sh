#!/usr/bin/env bash
# owner: session-start-cycle-state
# _smoke-test-session-start-cycle.sh — Verify the session-start
# cycle-state detection (issue #167).
#
# Covers (per docs/specs/session-start-cycle-state.spec.md):
#   1. branch != main, no spec/plan          → section omitted
#   2. branch != main, design spec only      → phase = pre-implementation
#   3. branch != main, plan with 0% checked  → phase = ready to start implementation
#   4. branch != main, plan with mid %       → phase = mid-implementation, N remain
#   5. branch != main, plan with 100% checked → phase = ready for /finish
#   6. branch == main                         → section omitted
#
# Usage: bash scripts/_smoke-test-session-start-cycle.sh
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
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; printf '%s\n' "$2" >&2; }
  exit 1
}

ok() { echo "PASS: $1"; }

# ── Helper: build a fixture project on a given branch ────────────────

new_fixture() {
  local name="$1"
  local branch="$2"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/docs/definitions" "$fix/docs/specs" \
           "$fix/docs/superpowers/specs" "$fix/docs/superpowers/plans" \
           "$fix/docs/plans" \
           "$fix/.claude/hooks" "$fix/.arboretum"
  echo "# fixture" > "$fix/docs/ARCHITECTURE.md"
  echo "# fixture" > "$fix/docs/REGISTER.md"
  echo "# fixture" > "$fix/contracts.yaml"
  cat > "$fix/.arboretum.yml" <<EOF
layer: 0
EOF
  cp "$HOOK" "$fix/.claude/hooks/session-start.sh"

  # git init + check out the requested branch.
  # Avoid `git init -b <name>` (Git 2.28+) for broader compatibility with
  # older git versions; rename via `branch -M main` after the seed commit.
  git -C "$fix" init -q
  git -C "$fix" config user.email "fixture@example.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" -c commit.gpgsign=false -c gpg.program=true \
      commit -q --allow-empty -m "fixture seed" >/dev/null 2>&1
  git -C "$fix" branch -M main
  if [ "$branch" != "main" ]; then
    git -C "$fix" checkout -q -b "$branch"
  fi

  echo "$fix"
}

run_hook() {
  local fix="$1"
  ( cd "$fix" && CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" 2>&1 )
}

# ── Case 1: branch != main, no spec/plan → section omitted ─────────

case1() {
  local fix; fix=$(new_fixture case1 "feat/foo")
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q "\[Build cycle\]"; then
    fail "case1: [Build cycle] section appeared with no spec/plan present" "$out"
  fi
  ok "case1: branch != main, no spec/plan → section omitted"
}

# ── Case 2: design spec only → phase = pre-implementation ──────────

case2() {
  local fix; fix=$(new_fixture case2 "feat/foo")
  echo "# Design spec" > "$fix/docs/superpowers/specs/2026-04-29-foo-design.md"
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "\[Build cycle\]"     || fail "case2: missing [Build cycle]" "$out"
  echo "$out" | grep -q "feat/foo"            || fail "case2: missing branch" "$out"
  echo "$out" | grep -q "pre-implementation"  || fail "case2: wrong phase" "$out"
  ok "case2: design spec only → phase = pre-implementation"
}

# ── Case 3: plan with 0% checked → phase = ready to start ──────────

case3() {
  local fix; fix=$(new_fixture case3 "feat/foo")
  echo "# Design spec" > "$fix/docs/superpowers/specs/2026-04-29-foo-design.md"
  cat > "$fix/docs/plans/2026-04-29-foo.md" <<'EOF'
# Plan
- [ ] Task A
- [ ] Task B
- [ ] Task C
EOF
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "ready to start implementation" || fail "case3: wrong phase" "$out"
  echo "$out" | grep -q "0/3 tasks complete"            || fail "case3: wrong progress" "$out"
  ok "case3: plan with 0% checked → ready to start implementation"
}

# ── Case 4: plan with mid % → phase = mid-implementation, N remain ─

case4() {
  local fix; fix=$(new_fixture case4 "feat/foo")
  echo "# Design spec" > "$fix/docs/superpowers/specs/2026-04-29-foo-design.md"
  cat > "$fix/docs/plans/2026-04-29-foo.md" <<'EOF'
# Plan
- [x] Task A
- [x] Task B
- [ ] Task C
- [ ] Task D
- [ ] Task E
EOF
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "mid-implementation"     || fail "case4: wrong phase" "$out"
  echo "$out" | grep -q "3 tasks remain"          || fail "case4: wrong remaining count" "$out"
  echo "$out" | grep -q "2/5 tasks complete"      || fail "case4: wrong progress" "$out"
  ok "case4: plan with mid % → mid-implementation, 3 remain"
}

# ── Case 5: plan with 100% checked → phase = ready for /finish ─────

case5() {
  local fix; fix=$(new_fixture case5 "feat/foo")
  echo "# Design spec" > "$fix/docs/superpowers/specs/2026-04-29-foo-design.md"
  cat > "$fix/docs/plans/2026-04-29-foo.md" <<'EOF'
# Plan
- [x] Task A
- [x] Task B
EOF
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q "ready for /finish" || fail "case5: wrong phase" "$out"
  echo "$out" | grep -q "2/2 tasks complete" || fail "case5: wrong progress" "$out"
  ok "case5: plan with 100% checked → ready for /finish"
}

# ── Case 6: branch == main → section omitted ───────────────────────

case6() {
  local fix; fix=$(new_fixture case6 "main")
  echo "# Design spec" > "$fix/docs/superpowers/specs/2026-04-29-foo-design.md"
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q "\[Build cycle\]"; then
    fail "case6: [Build cycle] section appeared on main branch" "$out"
  fi
  ok "case6: branch == main → section omitted"
}

case1
case2
case3
case4
case5
case6

echo
echo "All cycle-state smoke cases passed."
