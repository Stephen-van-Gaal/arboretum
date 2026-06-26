#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# Smoke test for docs/contracts/seed-settings.cli-contract.md.
# Exercises CLI-1..CLI-5 via temp-file fixtures. Never touches the live
# repo. Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/seed-settings.sh"

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

fail=0

# ---------------------------------------------------------------------------
# Helper — run the script, capture stdout+stderr+rc, assert expectations.
# run_ok  <name> <expected_stdout_substr_or_empty> <args...>
# run_fail <name> <expected_rc> <args...>
# ---------------------------------------------------------------------------

run_ok() {
  local name="$1" stdout_substr="$2"
  shift 2
  local out err rc
  out="$(bash "$SCRIPT" "$@" 2>/tmp/_smoke_seed_stderr)"
  rc=$?
  err="$(cat /tmp/_smoke_seed_stderr)"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name — expected exit 0, got $rc" >&2
    echo "  stdout: $out" >&2
    echo "  stderr: $err" >&2
    fail=1
  elif [ -n "$stdout_substr" ] && ! echo "$out" | grep -qF "$stdout_substr"; then
    echo "FAIL: $name — expected stdout to contain '$stdout_substr'; got: $out" >&2
    fail=1
  else
    echo "PASS: $name (exit 0)"
  fi
}

run_fail() {
  local name="$1" expected_rc="$2"
  shift 2
  local out err rc
  out="$(bash "$SCRIPT" "$@" 2>/tmp/_smoke_seed_stderr)"
  rc=$?
  err="$(cat /tmp/_smoke_seed_stderr)"
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: $name — expected exit $expected_rc, got $rc" >&2
    echo "  stdout: $out" >&2
    echo "  stderr: $err" >&2
    fail=1
  else
    echo "PASS: $name (exit $rc as expected)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario A — CLI-1: copy-on-absent
# Target does not exist; template is a valid settings.json with one allow entry.
# Script must copy verbatim and exit 0.
# ---------------------------------------------------------------------------
DIR_A="$TMPDIR_ROOT/a"
mkdir -p "$DIR_A"
TEMPLATE_A="$DIR_A/template.json"
TARGET_A="$DIR_A/settings.json"
cat > "$TEMPLATE_A" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(scripts/health-check.sh)"]
  }
}
JSON

run_ok "A: copy-on-absent (target missing → template copied)" "created" "$TARGET_A" "$TEMPLATE_A"

if [ "$fail" -eq 0 ]; then
  if ! diff -q "$TARGET_A" "$TEMPLATE_A" >/dev/null 2>&1; then
    echo "FAIL: A — target is not a verbatim copy of template" >&2
    fail=1
  else
    echo "PASS: A (target matches template byte-for-byte)"
  fi
fi

# ---------------------------------------------------------------------------
# Scenario B — CLI-2: merge-on-present (requires jq)
# Target already has one allow entry; template has two entries (one overlapping,
# one new). Script must exit 0 and the merged target must contain all three
# unique entries — no duplicates.
# ---------------------------------------------------------------------------
DIR_B="$TMPDIR_ROOT/b"
mkdir -p "$DIR_B"
TEMPLATE_B="$DIR_B/template.json"
TARGET_B="$DIR_B/settings.json"

cat > "$TARGET_B" <<'JSON'
{
  "hooks": {"PostToolUse": []},
  "permissions": {
    "allow": ["Bash(scripts/health-check.sh)"]
  }
}
JSON
cat > "$TEMPLATE_B" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(scripts/health-check.sh)",
      "Bash(scripts/generate-register.sh)"
    ]
  }
}
JSON

if command -v jq >/dev/null 2>&1; then
  run_ok "B: merge-on-present (jq available)" "merged allow list" "$TARGET_B" "$TEMPLATE_B"

  if [ "$fail" -eq 0 ]; then
    # Assert merged target contains both original + new entries, no duplicates.
    COUNT="$(jq '.permissions.allow | length' "$TARGET_B" 2>/dev/null)"
    if [ "$COUNT" != "2" ]; then
      echo "FAIL: B — expected 2 unique allow entries after merge, got $COUNT" >&2
      fail=1
    else
      echo "PASS: B ($COUNT unique entries; no duplicates)"
    fi

    # Original allow entry still present.
    if ! jq -e '.permissions.allow | index("Bash(scripts/health-check.sh)")' "$TARGET_B" >/dev/null 2>&1; then
      echo "FAIL: B — original allow entry missing after merge" >&2
      fail=1
    else
      echo "PASS: B (original allow entry preserved)"
    fi

    # New allow entry added.
    if ! jq -e '.permissions.allow | index("Bash(scripts/generate-register.sh)")' "$TARGET_B" >/dev/null 2>&1; then
      echo "FAIL: B — new template allow entry missing after merge" >&2
      fail=1
    else
      echo "PASS: B (new template allow entry added)"
    fi

    # Hooks key preserved.
    if ! jq -e '.hooks' "$TARGET_B" >/dev/null 2>&1; then
      echo "FAIL: B — hooks key missing from merged target" >&2
      fail=1
    else
      echo "PASS: B (hooks key preserved)"
    fi
  fi
else
  # CLI-4 path: jq absent — assert graceful degradation instead of CLI-2.
  echo "INFO: jq not found — skipping CLI-2 merge assertion; exercising CLI-4 (graceful degradation) instead"
  ORIGINAL_MTIME="$(stat -c '%Y' "$TARGET_B" 2>/dev/null || stat -f '%m' "$TARGET_B" 2>/dev/null)"
  run_ok "B→CLI-4: jq-absent graceful degradation (exit 0, no write)" "" "$TARGET_B" "$TEMPLATE_B"
  NEW_MTIME="$(stat -c '%Y' "$TARGET_B" 2>/dev/null || stat -f '%m' "$TARGET_B" 2>/dev/null)"
  if [ "$ORIGINAL_MTIME" != "$NEW_MTIME" ]; then
    echo "FAIL: CLI-4 — target was modified despite jq absent" >&2
    fail=1
  else
    echo "PASS: CLI-4 (target unchanged when jq absent)"
  fi
  # Also assert that stderr contains an actionable message.
  bash "$SCRIPT" "$TARGET_B" "$TEMPLATE_B" 2>/tmp/_smoke_seed_b_err || true
  if ! grep -q "jq not found" /tmp/_smoke_seed_b_err; then
    echo "FAIL: CLI-4 — expected actionable stderr message about jq; got: $(cat /tmp/_smoke_seed_b_err)" >&2
    fail=1
  else
    echo "PASS: CLI-4 (actionable stderr message present)"
  fi
fi

# ---------------------------------------------------------------------------
# Scenario C — CLI-3: missing-template exits 1
# Template path does not exist; script must exit 1 and emit an error to stderr.
# ---------------------------------------------------------------------------
DIR_C="$TMPDIR_ROOT/c"
mkdir -p "$DIR_C"
TARGET_C="$DIR_C/settings.json"
# No template file created.

bash "$SCRIPT" "$TARGET_C" "$DIR_C/nonexistent-template.json" >/tmp/_smoke_seed_c_out 2>/tmp/_smoke_seed_c_err
RC_C=$?
if [ "$RC_C" -ne 1 ]; then
  echo "FAIL: C — expected exit 1 for missing template, got $RC_C" >&2
  fail=1
elif ! grep -q "template not found" /tmp/_smoke_seed_c_err; then
  echo "FAIL: C — expected 'template not found' in stderr; got: $(cat /tmp/_smoke_seed_c_err)" >&2
  fail=1
else
  echo "PASS: C (exit 1 + 'template not found' in stderr)"
fi

# ---------------------------------------------------------------------------
# Scenario D — CLI-4: jq-absent graceful degradation.
# When jq is genuinely absent (exercised in the B else-branch above when
# jq is not installed), we also verify the documented jq-absent behavior
# here via a helper script that removes jq from the child environment.
# On systems where jq is present we use a wrapper script that overrides the
# `command` built-in via a shell function so `command -v jq` reports absent.
# ---------------------------------------------------------------------------
DIR_D="$TMPDIR_ROOT/d"
mkdir -p "$DIR_D"
TEMPLATE_D="$DIR_D/template.json"
TARGET_D="$DIR_D/settings.json"
cat > "$TARGET_D" <<'JSON'
{"permissions":{"allow":["Bash(scripts/health-check.sh)"]}}
JSON
cat > "$TEMPLATE_D" <<'JSON'
{"permissions":{"allow":["Bash(scripts/generate-register.sh)"]}}
JSON
ORIGINAL_D="$(cat "$TARGET_D")"

# Wrapper that shells out to seed-settings.sh with `command` overridden so
# `command -v jq` reports not-found, without hiding bash or other tools.
WRAPPER_D="$TMPDIR_ROOT/run-no-jq.sh"
cat > "$WRAPPER_D" <<WRAPPER
#!/usr/bin/env bash
# Shadow 'command' so 'command -v jq' returns failure while all other
# invocations pass through to the real built-in.
command() {
  if [ "\$1" = "-v" ] && [ "\$2" = "jq" ]; then return 1; fi
  builtin command "\$@"
}
export -f command
exec bash "$SCRIPT" "\$@"
WRAPPER
chmod +x "$WRAPPER_D"

bash "$WRAPPER_D" "$TARGET_D" "$TEMPLATE_D" >/tmp/_smoke_seed_d_out 2>/tmp/_smoke_seed_d_err
RC_D=$?
AFTER_D="$(cat "$TARGET_D")"

if [ "$RC_D" -ne 0 ]; then
  echo "FAIL: D — expected exit 0 when jq absent, got $RC_D" >&2
  fail=1
elif [ "$ORIGINAL_D" != "$AFTER_D" ]; then
  echo "FAIL: D — target was modified despite jq absent" >&2
  fail=1
elif ! grep -q "jq not found" /tmp/_smoke_seed_d_err; then
  echo "FAIL: D — expected 'jq not found' in stderr; got: $(cat /tmp/_smoke_seed_d_err)" >&2
  fail=1
else
  echo "PASS: D (jq-absent: exit 0, target unchanged, actionable stderr)"
fi

# ---------------------------------------------------------------------------
# Scenario E — CLI-5: atomic write (temp-then-mv, target never left truncated)
# This is a structural invariant the smoke test can only partially verify:
# we confirm the final target is valid JSON (not corrupted) after a merge.
# The atomic-write guarantee itself is code-level; here we assert the result
# is readable and correct.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  DIR_E="$TMPDIR_ROOT/e"
  mkdir -p "$DIR_E"
  TEMPLATE_E="$DIR_E/template.json"
  TARGET_E="$DIR_E/settings.json"
  cat > "$TARGET_E" <<'JSON'
{"permissions":{"allow":["Bash(git status)"]}}
JSON
  cat > "$TEMPLATE_E" <<'JSON'
{"permissions":{"allow":["Bash(git status)","Bash(git log)"]}}
JSON

  run_ok "E: atomic write — result is valid JSON" "merged allow list" "$TARGET_E" "$TEMPLATE_E"

  if jq empty "$TARGET_E" 2>/dev/null; then
    echo "PASS: E (merged target is valid JSON)"
  else
    echo "FAIL: E — merged target is not valid JSON" >&2
    fail=1
  fi
else
  echo "INFO: jq not available — skipping scenario E"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
