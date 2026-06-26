#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: serial
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/cleanup/SKILL.md"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q 'cleanup driver' "$SKILL" || fail "skill does not mention the cleanup driver"
grep -q -- '--plan' "$SKILL" || fail "skill does not reference the helper --plan mode"
grep -q 'active' "$SKILL" || fail "skill does not address the active-worktree terminal case"
# The terminal --execute must be described as a main-thread action, not delegated.
grep -q 'main thread' "$SKILL" || fail "skill does not keep the terminal action in the main thread"
pass "cleanup skill describes driver delegation with main-thread terminal action"
