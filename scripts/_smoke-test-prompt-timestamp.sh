#!/usr/bin/env bash
# owner: prompt-timestamps
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-prompt-timestamp.sh — Verify .claude/hooks/prompt-timestamp.sh
# emits exactly one well-formed dated wall-clock line and exits 0, per the
# UserPromptSubmit hook contract documented in
# docs/superpowers/specs/2026-05-28-prompt-timestamps-design.md.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/prompt-timestamp.sh"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

[ -x "$HOOK" ] || fail "hook missing or not executable" "$HOOK"

# ── Case 1: output matches the documented dated line shape ────────────
out=$("$HOOK")
# Format: [YYYY-MM-DD HH:MM:SS] user prompt submitted
echo "$out" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-2][0-9]:[0-5][0-9]:[0-5][0-9]\] user prompt submitted$' \
  || fail "case 1 — output does not match documented shape" "got: $out"
ok "case 1 — dated wall-clock line shape"

# ── Case 2: exactly one line on stdout, exit 0 ────────────────────────
# The hook contract: one line of additionalContext per UserPromptSubmit
# event. More than one line would pollute the transcript; fewer (zero)
# would silently fail to anchor the prompt.
lines=$("$HOOK" | wc -l | tr -d ' ')
[ "$lines" = "1" ] || fail "case 2 — expected exactly 1 line of stdout, got $lines"
"$HOOK" >/dev/null || fail "case 2 — hook exited non-zero"
ok "case 2 — exactly one stdout line, exit 0"

# ── Case 3: hook exits 0 even when date(1) fails ─────────────────────
# The Failure mode section of the governed spec promises silent unstamped
# submission rather than non-zero exit when date(1) is unavailable. This
# is implemented by `|| true` in the hook. Shadow `date` with a stub that
# always returns 1 and confirm the hook still exits 0 (the `|| true` is
# what makes the spec's documented failure mode true).
SHADOW=$(mktemp -d)
trap 'rm -rf "$SHADOW"' EXIT
ln -sf /usr/bin/false "$SHADOW/date"
PATH="$SHADOW:$PATH" "$HOOK" >/dev/null 2>&1 \
  || fail "case 3 — hook must exit 0 even when date(1) fails (|| true regression)"
ok "case 3 — hook exits 0 when date(1) fails (|| true invariant)"

echo
echo "prompt-timestamp smoke tests passed."
exit 0
