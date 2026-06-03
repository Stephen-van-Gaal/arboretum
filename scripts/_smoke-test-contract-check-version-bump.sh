#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/contracts/check-version-bump.cli-contract.md.
# Exercises CLI-1..CLI-8 via fixture git repos driven by REPO_ROOT + BASE_REF.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-version-bump.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

# Identity flags used for every fixture commit — keeps CI runners without a
# global git config from failing at "Author identity unknown".
GIT_ID=(-c user.email=t@t -c user.name=t)

# All fixtures live under a single mktemp root; trap cleans them on exit.
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT" 2>/dev/null' EXIT

fail=0

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# init_repo <dir> — initialise a bare git repo with an initial empty commit
# on branch 'base' (the merge-base reference for all scenarios).  Returns with
# the working tree on branch 'base'.
init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" "${GIT_ID[@]}" init -q
  git -C "$dir" "${GIT_ID[@]}" checkout -q -b base
  git -C "$dir" "${GIT_ID[@]}" commit -q --allow-empty -m "init"
}

# write_plugin_json <dir> <version> — write self-consistent Claude and Codex
# plugin manifests with the given version string.
write_plugin_json() {
  local dir="$1" ver="$2"
  mkdir -p "$dir/.claude-plugin" "$dir/.codex-plugin"
  printf '{"version":"%s"}' "$ver" > "$dir/.claude-plugin/plugin.json"
  printf '{"version":"%s","plugins":[{"version":"%s"}]}' "$ver" "$ver" \
    > "$dir/.claude-plugin/marketplace.json"
  printf '{"version":"%s"}' "$ver" > "$dir/.codex-plugin/plugin.json"
}

# commit_all <dir> <message> — stage everything in <dir> and commit.
commit_all() {
  local dir="$1" msg="$2"
  git -C "$dir" "${GIT_ID[@]}" add -A
  git -C "$dir" "${GIT_ID[@]}" commit -q -m "$msg"
}

# run_check <repo_root> <base_ref> — invoke the script with REPO_ROOT and
# BASE_REF overridden; return the exit code.
run_check() {
  local repo_root="$1" base_ref="$2"
  env -u RELEASE_INTENT_BODY_FILE -u RELEASE_INTENT_EVENT \
    REPO_ROOT="$repo_root" BASE_REF="$base_ref" bash "$SCRIPT"
}

run_check_with_body() {
  local repo_root="$1" base_ref="$2" body_file="$3"
  env -u RELEASE_INTENT_EVENT \
    RELEASE_INTENT_BODY_FILE="$body_file" \
    REPO_ROOT="$repo_root" BASE_REF="$base_ref" bash "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Scenario: CLI-1 + CLI-2 — consistent versions, no shippable content changed
# ---------------------------------------------------------------------------
#   Build: base commit has version 1.0.0 in both JSON files.  HEAD also has
#   1.0.0 but only touches a dev-only path (docs/specs/).  Expected: exit 0.
REPO_A="$FIXTURE_ROOT/repo-a"
init_repo "$REPO_A"
write_plugin_json "$REPO_A" "1.0.0"
commit_all "$REPO_A" "base: add plugin json at 1.0.0"

# Branch off for the "PR" commits.
git -C "$REPO_A" "${GIT_ID[@]}" checkout -q -b pr-branch
# Touch only a dev-only file — this must not count as shippable.
mkdir -p "$REPO_A/docs/specs"
printf 'spec content\n' > "$REPO_A/docs/specs/example.spec.md"
commit_all "$REPO_A" "pr: add dev-only spec (no shippable change)"

rc=0
out=$(run_check "$REPO_A" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "no shippable content changed"; then
  echo "PASS: CLI-1+CLI-2 — consistent versions, dev-only change → exit 0"
else
  echo "FAIL: CLI-1+CLI-2 — expected exit 0 + 'no shippable content changed'; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-3 — consistent versions, shippable content changed, bump present
# ---------------------------------------------------------------------------
#   Build on top of repo-a's base: HEAD has version 1.1.0, touches a
#   shippable path (skills/finish/SKILL.md).  Expected: exit 0.
REPO_B="$FIXTURE_ROOT/repo-b"
init_repo "$REPO_B"
write_plugin_json "$REPO_B" "1.0.0"
mkdir -p "$REPO_B/skills/finish"
printf 'SKILL content\n' > "$REPO_B/skills/finish/SKILL.md"
commit_all "$REPO_B" "base: add plugin json at 1.0.0 + skill stub"

git -C "$REPO_B" "${GIT_ID[@]}" checkout -q -b pr-branch
write_plugin_json "$REPO_B" "1.1.0"
printf 'Updated SKILL content\n' > "$REPO_B/skills/finish/SKILL.md"
commit_all "$REPO_B" "pr: bump to 1.1.0 and update skill (shippable)"

rc=0
out=$(run_check "$REPO_B" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "version bumped"; then
  echo "PASS: CLI-3 — shippable content + bump present → exit 0"
else
  echo "FAIL: CLI-3 — expected exit 0 + 'version bumped'; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-4 — consistent versions, shippable content changed, no release intent input yet
# ---------------------------------------------------------------------------
#   Build: base and HEAD share the same version 1.0.0, but HEAD touches a
#   shippable path.  Expected: exit 0 pre-PR skip.
REPO_C="$FIXTURE_ROOT/repo-c"
init_repo "$REPO_C"
write_plugin_json "$REPO_C" "1.0.0"
mkdir -p "$REPO_C/skills/finish"
printf 'SKILL content\n' > "$REPO_C/skills/finish/SKILL.md"
commit_all "$REPO_C" "base: add plugin json at 1.0.0 + skill stub"

git -C "$REPO_C" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'Updated SKILL content\n' > "$REPO_C/skills/finish/SKILL.md"
# Version intentionally left at 1.0.0 — no bump.
commit_all "$REPO_C" "pr: update skill without bumping version"

rc=0
out=$(run_check "$REPO_C" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "release intent input not available"; then
  echo "PASS: CLI-4 — shippable content without release intent input → pre-PR skip"
else
  echo "FAIL: CLI-4 — expected exit 0 + 'release intent input not available'; got rc=$rc output: $out" >&2
  fail=1
fi

# Scenario: CLI-4b — supplied invalid release intent remains blocking
printf '## Summary\nmissing intent\n' > "$REPO_C/body.md"
rc=0
out=$(run_check_with_body "$REPO_C" base "$REPO_C/body.md" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "release intent is missing"; then
  echo "PASS: CLI-4b — supplied invalid release intent → exit 1"
else
  echo "FAIL: CLI-4b — expected exit 1 + 'release intent is missing'; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-7 — public report issue forms are shippable despite .github/
# ---------------------------------------------------------------------------
#   Build: base and HEAD share the same version 1.0.0, but HEAD touches the
#   issue-form mirror that sync-public.yml copies after excluding .github/.
#   Expected: pre-PR skip without body; supplied invalid intent fails.
REPO_E="$FIXTURE_ROOT/repo-e"
init_repo "$REPO_E"
write_plugin_json "$REPO_E" "1.0.0"
mkdir -p "$REPO_E/.github/ISSUE_TEMPLATE"
printf 'problem form\n' > "$REPO_E/.github/ISSUE_TEMPLATE/arboretum-problem.md"
commit_all "$REPO_E" "base: add plugin json at 1.0.0 + report form"

git -C "$REPO_E" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated problem form\n' > "$REPO_E/.github/ISSUE_TEMPLATE/arboretum-problem.md"
commit_all "$REPO_E" "pr: update public report form without bumping version"

rc=0
out=$(run_check "$REPO_E" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "release intent input not available"; then
  echo "PASS: CLI-7 — public report issue-form without release intent input → pre-PR skip"
else
  echo "FAIL: CLI-7 — expected pre-PR skip; got rc=$rc output: $out" >&2
  fail=1
fi
printf '## Summary\nmissing intent\n' > "$REPO_E/body.md"
rc=0
out=$(run_check_with_body "$REPO_E" base "$REPO_E/body.md" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "release intent is missing"; then
  echo "PASS: CLI-7b — public report issue-form with invalid supplied intent → exit 1"
else
  echo "FAIL: CLI-7b — expected exit 1 + 'release intent is missing'; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-1 (version-consistency gate) — version occurrences disagree
# ---------------------------------------------------------------------------
#   Build: plugin.json says 1.2.0, marketplace.json says 1.1.0.  The
#   script must fail before reaching the shippable-content check.
#   Expected: exit 1.
REPO_D="$FIXTURE_ROOT/repo-d"
init_repo "$REPO_D"
write_plugin_json "$REPO_D" "1.0.0"
commit_all "$REPO_D" "base: add plugin json at 1.0.0"

git -C "$REPO_D" "${GIT_ID[@]}" checkout -q -b pr-branch
# Write inconsistent versions directly.
printf '{"version":"1.2.0"}' > "$REPO_D/.claude-plugin/plugin.json"
printf '{"version":"1.1.0","plugins":[{"version":"1.1.0"}]}' \
  > "$REPO_D/.claude-plugin/marketplace.json"
commit_all "$REPO_D" "pr: inconsistent versions (1.2.0 vs 1.1.0)"

rc=0
out=$(run_check "$REPO_D" base 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "plugin version occurrences disagree"; then
  echo "PASS: CLI-1 — version inconsistency → exit 1"
else
  echo "FAIL: CLI-1 — expected exit 1 + 'plugin version occurrences disagree'; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-5 + CLI-6 — BASE_REF and REPO_ROOT seams exercised together
# ---------------------------------------------------------------------------
#   Reuse repo-b (bump-present fixture). Verify that pointing BASE_REF at
#   the correct local branch and REPO_ROOT at the fixture directory produces
#   the same exit-0 result as the CLI-3 scenario — confirming both env
#   overrides are honoured.  If either seam were ignored, BASE_REF would
#   fall back to origin/main (unreachable in a bare fixture) or REPO_ROOT
#   would point at the live repo and fail for unrelated reasons.
rc=0
out=$(run_check "$REPO_B" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: CLI-5+CLI-6 — BASE_REF + REPO_ROOT seams honoured → exit 0"
else
  echo "FAIL: CLI-5+CLI-6 — expected exit 0 with both seams set; got rc=$rc output: $out" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# Scenario: CLI-8 — no plugin manifests means consumer/not-plugin root
# ---------------------------------------------------------------------------
REPO_F="$FIXTURE_ROOT/repo-f"
init_repo "$REPO_F"
mkdir -p "$REPO_F/scripts"
printf '#!/usr/bin/env bash\n' > "$REPO_F/scripts/example.sh"
commit_all "$REPO_F" "base: no plugin manifests"

git -C "$REPO_F" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'changed\n' > "$REPO_F/scripts/example.sh"
commit_all "$REPO_F" "pr: script edit in consumer root"

rc=0
out=$(run_check "$REPO_F" base 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "plugin version manifests not found"; then
  echo "PASS: CLI-8a — no plugin manifests → consumer skip"
else
  echo "FAIL: CLI-8a — expected exit 0 + consumer skip; got rc=$rc output: $out" >&2
  fail=1
fi

REPO_G="$FIXTURE_ROOT/repo-g"
init_repo "$REPO_G"
mkdir -p "$REPO_G/.codex-plugin"
printf '{"version":"1.0.0"}' > "$REPO_G/.codex-plugin/plugin.json"
commit_all "$REPO_G" "base: partial plugin manifests"

git -C "$REPO_G" "${GIT_ID[@]}" checkout -q -b pr-branch
printf '{"version":"1.0.1"}' > "$REPO_G/.codex-plugin/plugin.json"
commit_all "$REPO_G" "pr: partial plugin manifest edit"

rc=0
out=$(run_check "$REPO_G" base 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "plugin version manifest set is incomplete"; then
  echo "PASS: CLI-8b — partial plugin manifest set fails"
else
  echo "FAIL: CLI-8b — expected partial manifest failure; got rc=$rc output: $out" >&2
  fail=1
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
