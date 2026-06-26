#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# Smoke test for docs/contracts/bootstrap-project.cli-contract.md.
# Exercises CLI-1 through CLI-10 directly by running bootstrap-project.sh
# against temp fixture directories. Picked up automatically by ci-checks.sh's
# === Smoke tests === loop.
#
# History: invariants CLI-1c, CLI-2 (exit-0), CLI-3 (.githooks/skills), CLI-4b,
# CLI-4c, CLI-5, CLI-6, CLI-7, CLI-8 were previously pinned with skip markers
# because bootstrap-project.sh aborted mid-run on `cp` of a template
# subdirectory (issue-templates/). #420 made copy_if_missing directory-aware
# (cp -R + -e guard), so the run now completes and every invariant is a real
# assertion.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-project.sh"

[ -f "$BOOTSTRAP" ] || { echo "FAIL: bootstrap-project.sh not found at $BOOTSTRAP" >&2; exit 1; }

fail=0

pass()      { echo "PASS: $1"; }
fail_msg()  { echo "FAIL: $1" >&2; fail=1; }

# ── Fixture setup ────────────────────────────────────────────────────────────
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

TARGET="$TMPBASE/fresh"

# ── CLI-1c: valid-target run exits 0 ─────────────────────────────────────────
bootstrap_rc=0
bash "$BOOTSTRAP" "$TARGET" "MyProject" >/dev/null 2>&1 || bootstrap_rc=$?
if [ "$bootstrap_rc" -eq 0 ]; then
  pass "CLI-1c: valid-target run exits 0"
else
  fail_msg "CLI-1c: valid-target run — expected exit 0, got $bootstrap_rc"
fi

# ── CLI-1: Positional-arg and exit-code contract ─────────────────────────────
# No-arg invocation must exit 1 with a usage message.
no_arg_rc=0
no_arg_out=$(bash "$BOOTSTRAP" 2>&1) || no_arg_rc=$?
if [ "$no_arg_rc" -eq 1 ]; then
  pass "CLI-1a: no-arg invocation exits 1"
else
  fail_msg "CLI-1a: no-arg invocation — expected exit 1, got $no_arg_rc"
fi
if echo "$no_arg_out" | grep -qi "usage\|target-directory"; then
  pass "CLI-1b: no-arg invocation prints usage message"
else
  fail_msg "CLI-1b: no-arg invocation — expected usage message; got: $no_arg_out"
fi

# ── CLI-2: Idempotent re-run ─────────────────────────────────────────────────
# Second run against the same target must exit 0 (every copy is now guarded by
# the -e existence check) and must not overwrite or nest existing artefacts.
rerun_rc=0
bash "$BOOTSTRAP" "$TARGET" "MyProject" >/dev/null 2>&1 || rerun_rc=$?
if [ "$rerun_rc" -eq 0 ]; then
  pass "CLI-2: second run exits 0"
else
  fail_msg "CLI-2: second run — expected exit 0, got $rerun_rc"
fi
# Directories created in the first run must still be present.
for dir in docs docs/specs docs/templates workflows ".claude/hooks"; do
  if [ -d "$TARGET/$dir" ]; then
    pass "CLI-2: second run preserved directory — $dir"
  else
    fail_msg "CLI-2: second run — directory missing after re-run: $TARGET/$dir"
  fi
done
# The -e guard must prevent cp -R from nesting a directory template inside its
# already-present destination on the second run.
if [ ! -e "$TARGET/docs/templates/issue-templates/issue-templates" ]; then
  pass "CLI-2: re-run did not nest directory template (issue-templates/)"
else
  fail_msg "CLI-2: re-run nested issue-templates/ inside itself — idempotency guard failed"
fi

# ── CLI-3: Core directory structure created ───────────────────────────────────
# After a successful run the full directory set must be present, including the
# .githooks/ and .claude/skills/ trees that only appear post-template-copy.
for dir in docs docs/specs docs/templates workflows ".claude/hooks" ".githooks" ".claude/skills"; do
  if [ -d "$TARGET/$dir" ]; then
    pass "CLI-3: directory created — $dir"
  else
    fail_msg "CLI-3: expected directory missing — $TARGET/$dir"
  fi
done

# ── CLI-4: Agent adapters rendered with project name ──────────────────────────
# Templates land in docs/templates/; rendered root adapters carry the name.
if [ -f "$TARGET/docs/templates/CLAUDE.md" ]; then
  pass "CLI-4a: CLAUDE.md template copied to docs/templates/"
else
  fail_msg "CLI-4a: CLAUDE.md template not found in docs/templates/"
fi
if [ -f "$TARGET/docs/templates/AGENTS.md" ]; then
  pass "CLI-4a: AGENTS.md template copied to docs/templates/"
else
  fail_msg "CLI-4a: AGENTS.md template not found in docs/templates/"
fi
if [ -f "$TARGET/ARBORETUM.md" ]; then
  pass "CLI-10: ARBORETUM.md copied to project root"
else
  fail_msg "CLI-10: ARBORETUM.md not copied to project root"
fi
if [ -f "$TARGET/CLAUDE.md" ] && grep -q "^# CLAUDE.md — MyProject" "$TARGET/CLAUDE.md"; then
  pass "CLI-4b: rendered CLAUDE.md at project root carries project name"
else
  fail_msg "CLI-4b: rendered root CLAUDE.md missing project-name heading"
fi
if [ -f "$TARGET/AGENTS.md" ] && grep -q "^# AGENTS.md — MyProject" "$TARGET/AGENTS.md"; then
  pass "CLI-4c: rendered AGENTS.md at project root carries project name"
else
  fail_msg "CLI-4c: rendered root AGENTS.md missing project-name heading"
fi

# ── CLI-5: .arboretum.yml created ────────────────────────────────────────────
if [ -f "$TARGET/.arboretum.yml" ] \
   && grep -qE '^layer:[[:space:]]*0' "$TARGET/.arboretum.yml" \
   && grep -qE '^backend:[[:space:]]*github' "$TARGET/.arboretum.yml"; then
  pass "CLI-5: .arboretum.yml created with layer: 0 and backend: github"
else
  fail_msg "CLI-5: .arboretum.yml missing or lacks layer:0 / backend:github"
fi

# ── CLI-6: Layer filter — pre-commit hook gated at Layer 2 ────────────────────
LAYER1="$TMPBASE/layer1"
bash "$BOOTSTRAP" --layer 1 "$LAYER1" L1 >/dev/null 2>&1 || true
if [ ! -f "$LAYER1/.claude/hooks/pre-commit-branch-check.sh" ]; then
  pass "CLI-6: --layer 1 omits pre-commit-branch-check.sh"
else
  fail_msg "CLI-6: --layer 1 unexpectedly copied pre-commit-branch-check.sh"
fi
LAYER2="$TMPBASE/layer2"
bash "$BOOTSTRAP" --layer 2 "$LAYER2" L2 >/dev/null 2>&1 || true
if [ -f "$LAYER2/.claude/hooks/pre-commit-branch-check.sh" ]; then
  pass "CLI-6: --layer 2 copies pre-commit-branch-check.sh"
else
  fail_msg "CLI-6: --layer 2 did not copy pre-commit-branch-check.sh"
fi

# ── CLI-7: Layer filter — settings.json variant ──────────────────────────────
# --layer 1: SessionStart-only, no PreToolUse. --layer 2: full settings.
if grep -q "SessionStart" "$LAYER1/.claude/settings.json" \
   && ! grep -q "PreToolUse" "$LAYER1/.claude/settings.json"; then
  pass "CLI-7: --layer 1 settings.json is SessionStart-only (no PreToolUse)"
else
  fail_msg "CLI-7: --layer 1 settings.json variant wrong (expected SessionStart, no PreToolUse)"
fi
if grep -q "PreToolUse" "$LAYER2/.claude/settings.json"; then
  pass "CLI-7: --layer 2 settings.json is the full installation copy (has PreToolUse)"
else
  fail_msg "CLI-7: --layer 2 settings.json missing PreToolUse — not the full copy"
fi

# ── CLI-8: Git repository initialised ────────────────────────────────────────
if [ -d "$TARGET/.git" ]; then
  pass "CLI-8: git repository initialised (.git/ present)"
else
  fail_msg "CLI-8: .git/ not created in target"
fi
hooks_path=$(cd "$TARGET" && git config core.hooksPath 2>/dev/null || true)
if [ "$hooks_path" = ".githooks" ]; then
  pass "CLI-8: core.hooksPath configured to .githooks"
else
  fail_msg "CLI-8: core.hooksPath not set to .githooks (got: '$hooks_path')"
fi

# ── CLI-9: Source-files-not-found guard ──────────────────────────────────────
# Copy the bootstrap script into a temp scripts/ dir that has no arboretum
# tree around it. SCRIPT_DIR resolves to the temp dir, so TEMPLATES_DIR
# becomes <tmpdir>/../docs/templates (doesn't exist). Under set -euo pipefail
# the `realpath "$SCRIPT_DIR/../docs/templates"` call (bootstrap-project.sh:58)
# aborts with a "No such file or directory" error *before* the explicit
# "Verify source files exist" guard is reached — so the assertable invariant
# is "non-zero exit with a missing-source diagnostic", NOT the friendly
# "run this script from the arboretum repo" message (which is unreachable on
# a missing templates dir).
FAKE_SCRIPTS="$TMPBASE/fake-scripts"
mkdir -p "$FAKE_SCRIPTS"
cp "$BOOTSTRAP" "$FAKE_SCRIPTS/bootstrap-project.sh"
TARGET_ORPHAN="$TMPBASE/orphan"
orphan_rc=0
orphan_out=$(bash "$FAKE_SCRIPTS/bootstrap-project.sh" "$TARGET_ORPHAN" 2>&1) || orphan_rc=$?
if [ "$orphan_rc" -ne 0 ] && echo "$orphan_out" | grep -qi "source file not found\|No such file or directory"; then
  pass "CLI-9: missing arboretum tree → non-zero exit with a missing-source diagnostic"
else
  fail_msg "CLI-9: expected non-zero exit with a missing-source diagnostic, got exit $orphan_rc: $orphan_out"
fi

# ── CLI-11: Dogfood mirror symlinks are skipped (design D5) ──────────────────
# The arboretum-dev .claude/skills/ tree carries the web-session mirror — symlinks
# into ../../skills/<name>. The bootstrap skill scan must skip them, or a fresh
# project gets a half-populated skill set (a callable /start that hands off to
# uninstalled commands). $TARGET was bootstrapped from the real repo above, so a
# surviving mirror name proves the skip is missing. (Guard the assertion on the
# source actually having a mirror entry, so this stays meaningful pre-mirror too.)
if [ -L "$SCRIPT_DIR/../.claude/skills/start" ]; then
  if [ ! -e "$TARGET/.claude/skills/start" ]; then
    pass "CLI-11: mirror symlink (start) skipped — not copied into bootstrapped project"
  else
    fail_msg "CLI-11: mirror symlink (start) was copied into the bootstrapped project"
  fi
else
  pass "CLI-11: no mirror entry present in source — skip-assertion vacuously holds"
fi

# ── Final result ─────────────────────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
