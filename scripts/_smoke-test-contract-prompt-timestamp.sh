#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# Smoke test for docs/contracts/prompt-timestamp.cli-contract.md.
# Exercises CLI-1..CLI-4 via four scenarios driving the hook directly.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/prompt-timestamp.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

fail=0

# TS_PATTERN — the documented output shape from CLI-1.
# Matches [YYYY-MM-DD HH:MM:SS] user prompt submitted (full line).
TS_PATTERN='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] user prompt submitted$'

# run_hook — invoke the hook, capture stdout/stderr, return rc.
# $1: scenario name (for error messages)
# Sets globals: _stdout, _stderr, _rc
run_hook() {
  shift  # $1 is the scenario label; callers embed it in their own messages
  local stdout_file stderr_file
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  trap 'rm -f "$stdout_file" "$stderr_file" 2>/dev/null' RETURN
  "$@" >"$stdout_file" 2>"$stderr_file"
  _rc=$?
  _stdout=$(cat "$stdout_file")
  _stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
}

# ── Scenario A — CLI-1 + CLI-2: normal invocation ──────────────────────────
# The hook emits exactly one line matching the timestamp pattern, exits 0.
run_hook "A: normal invocation" bash "$HOOK"
if [ "$_rc" -ne 0 ]; then
  echo "FAIL: A — expected exit 0, got $_rc" >&2
  fail=1
elif ! echo "$_stdout" | grep -qE "$TS_PATTERN"; then
  echo "FAIL: A — stdout does not match timestamp pattern" >&2
  echo "  got: $(echo "$_stdout" | cat -A)" >&2
  fail=1
elif [ -n "$_stderr" ]; then
  echo "FAIL: A — expected empty stderr, got: $_stderr" >&2
  fail=1
else
  echo "PASS: A — output matches timestamp pattern; exit 0; stderr empty"
fi

# ── Scenario B — CLI-1 line count: exactly one line ────────────────────────
# Pins CLI-1's "exactly one line" invariant. No trailing blank lines,
# no preamble — the hook should emit precisely one newline-terminated line.
run_hook "B: exactly one line" bash "$HOOK"
line_count=$(echo "$_stdout" | grep -c '' || true)
if [ "$line_count" -ne 1 ]; then
  echo "FAIL: B — expected exactly 1 output line, got $line_count" >&2
  echo "  stdout: $(echo "$_stdout" | cat -A)" >&2
  fail=1
else
  echo "PASS: B — exactly 1 output line"
fi

# ── Scenario C — CLI-3: no stderr output ───────────────────────────────────
# Pins CLI-3's zero-stderr invariant on the normal (success) path.
run_hook "C: no stderr output" bash "$HOOK"
if [ -n "$_stderr" ]; then
  echo "FAIL: C — expected empty stderr, got: $_stderr" >&2
  fail=1
else
  echo "PASS: C — stderr empty on success path"
fi

# ── Scenario D — CLI-2 + CLI-4: date(1) failure → silent unstamped exit 0 ──
# Replaces date(1) with a stub that always exits 1. The hook's `|| true`
# must absorb the failure: exit 0 with zero stdout bytes.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR" 2>/dev/null' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/date"
chmod +x "$STUB_DIR/date"

run_hook "D: date failure → silent unstamped exit 0" \
  env PATH="$STUB_DIR:$PATH" bash "$HOOK"
if [ "$_rc" -ne 0 ]; then
  echo "FAIL: D — expected exit 0 when date fails, got $_rc" >&2
  fail=1
elif [ -n "$_stdout" ]; then
  echo "FAIL: D — expected empty stdout when date fails, got: $_stdout" >&2
  fail=1
elif [ -n "$_stderr" ]; then
  echo "FAIL: D — expected empty stderr when date fails, got: $_stderr" >&2
  fail=1
else
  echo "PASS: D — date failure produces exit 0 and zero output (|| true holds)"
fi

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
