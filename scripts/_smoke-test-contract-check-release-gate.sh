#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# Smoke test for docs/dev-contracts/release/check-release-gate.cli-contract.md.
# Exercises release-gate behavior via isolated git fixtures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/dev-tools/release/check-release-gate.sh"
GIT_ID=(-c user.email=t@t -c user.name=t)
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

fail=0

init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" "${GIT_ID[@]}" init -q
  git -C "$dir" "${GIT_ID[@]}" checkout -q -b base
  git -C "$dir" "${GIT_ID[@]}" commit -q --allow-empty -m "init"
}

write_plugin_json() {
  local dir="$1" ver="$2"
  mkdir -p "$dir/.claude-plugin" "$dir/.codex-plugin"
  printf '{"version":"%s"}' "$ver" > "$dir/.claude-plugin/plugin.json"
  printf '{"version":"%s","plugins":[{"version":"%s"}]}' "$ver" "$ver" \
    > "$dir/.claude-plugin/marketplace.json"
  printf '{"version":"%s"}' "$ver" > "$dir/.codex-plugin/plugin.json"
}

commit_all() {
  local dir="$1" msg="$2"
  git -C "$dir" "${GIT_ID[@]}" add -A
  git -C "$dir" "${GIT_ID[@]}" commit -q -m "$msg"
}

write_intent_body() {
  local path="$1" impact="$2" state="$3"
  cat >"$path" <<BODY
## Release Intent
release-impact: $impact
release-state: $state
BODY
}

run_gate_clean() {
  local repo_root="$1"
  env -u RELEASE_INTENT_BODY_FILE -u RELEASE_INTENT_EVENT \
    REPO_ROOT="$repo_root" BASE_REF=base bash "$SCRIPT"
}

run_gate_with_body() {
  local repo_root="$1" body_file="$2"
  env -u RELEASE_INTENT_EVENT \
    RELEASE_INTENT_BODY_FILE="$body_file" REPO_ROOT="$repo_root" BASE_REF=base bash "$SCRIPT"
}

# A: dev-only diff passes without intent.
REPO_A="$FIXTURE_ROOT/repo-a"
init_repo "$REPO_A"
write_plugin_json "$REPO_A" "1.0.0"
commit_all "$REPO_A" "base manifests"
git -C "$REPO_A" "${GIT_ID[@]}" checkout -q -b pr-branch
mkdir -p "$REPO_A/docs/specs"
printf 'spec\n' > "$REPO_A/docs/specs/example.spec.md"
commit_all "$REPO_A" "dev-only change"
rc=0
out="$(run_gate_clean "$REPO_A" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "no shippable content changed"; then
  echo "PASS: dev-only diff without release intent"
else
  echo "FAIL: dev-only diff expected pass; rc=$rc output=$out" >&2
  fail=1
fi

# B: shippable non-manifest diff passes with pending patch intent.
REPO_B="$FIXTURE_ROOT/repo-b"
init_repo "$REPO_B"
write_plugin_json "$REPO_B" "1.0.0"
mkdir -p "$REPO_B/skills/pr"
printf 'skill\n' > "$REPO_B/skills/pr/SKILL.md"
commit_all "$REPO_B" "base skill"
git -C "$REPO_B" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated skill\n' > "$REPO_B/skills/pr/SKILL.md"
write_intent_body "$REPO_B/body.md" patch pending
commit_all "$REPO_B" "shippable change with intent"
rc=0
out="$(run_gate_with_body "$REPO_B" "$REPO_B/body.md" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "release intent patch pending"; then
  echo "PASS: shippable non-manifest diff with pending patch intent"
else
  echo "FAIL: shippable diff with intent expected pass; rc=$rc output=$out" >&2
  fail=1
fi

# C: shippable non-manifest diff skips when no intent input exists yet.
REPO_C="$FIXTURE_ROOT/repo-c"
init_repo "$REPO_C"
write_plugin_json "$REPO_C" "1.0.0"
mkdir -p "$REPO_C/skills/pr"
printf 'skill\n' > "$REPO_C/skills/pr/SKILL.md"
commit_all "$REPO_C" "base skill"
git -C "$REPO_C" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated skill\n' > "$REPO_C/skills/pr/SKILL.md"
commit_all "$REPO_C" "shippable change without intent"
rc=0
out="$(run_gate_clean "$REPO_C" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "release intent input not available"; then
  echo "PASS: shippable non-manifest diff without pre-PR intent skips"
else
  echo "FAIL: shippable diff without pre-PR intent expected skip; rc=$rc output=$out" >&2
  fail=1
fi

# C2: shippable non-manifest diff passes when supplied public PR body has no release intent.
REPO_C2="$FIXTURE_ROOT/repo-c2"
init_repo "$REPO_C2"
write_plugin_json "$REPO_C2" "1.0.0"
mkdir -p "$REPO_C2/skills/pr"
printf 'skill\n' > "$REPO_C2/skills/pr/SKILL.md"
commit_all "$REPO_C2" "base skill"
git -C "$REPO_C2" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated skill\n' > "$REPO_C2/skills/pr/SKILL.md"
printf '## Summary\nmissing intent\n' > "$REPO_C2/body.md"
commit_all "$REPO_C2" "shippable change with invalid intent"
rc=0
out="$(run_gate_with_body "$REPO_C2" "$REPO_C2/body.md" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "no release intent section declared"; then
  echo "PASS: shippable non-manifest diff with no supplied release intent passes"
else
  echo "FAIL: shippable diff with no supplied release intent expected pass; rc=$rc output=$out" >&2
  fail=1
fi

# C3: shippable non-manifest diff fails when supplied release intent is malformed.
REPO_C3="$FIXTURE_ROOT/repo-c3"
init_repo "$REPO_C3"
write_plugin_json "$REPO_C3" "1.0.0"
mkdir -p "$REPO_C3/skills/pr"
printf 'skill\n' > "$REPO_C3/skills/pr/SKILL.md"
commit_all "$REPO_C3" "base skill"
git -C "$REPO_C3" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated skill\n' > "$REPO_C3/skills/pr/SKILL.md"
write_intent_body "$REPO_C3/body.md" banana pending
commit_all "$REPO_C3" "shippable change with malformed intent"
rc=0
out="$(run_gate_with_body "$REPO_C3" "$REPO_C3/body.md" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "release intent is missing or invalid"; then
  echo "PASS: shippable non-manifest diff with malformed supplied intent fails"
else
  echo "FAIL: shippable diff with malformed supplied intent expected failure; rc=$rc output=$out" >&2
  fail=1
fi

# D: shippable non-manifest diff with release-impact none fails.
REPO_D="$FIXTURE_ROOT/repo-d"
init_repo "$REPO_D"
write_plugin_json "$REPO_D" "1.0.0"
mkdir -p "$REPO_D/skills/pr"
printf 'skill\n' > "$REPO_D/skills/pr/SKILL.md"
commit_all "$REPO_D" "base skill"
git -C "$REPO_D" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'updated skill\n' > "$REPO_D/skills/pr/SKILL.md"
write_intent_body "$REPO_D/body.md" none not-needed
commit_all "$REPO_D" "shippable change with none intent"
rc=0
out="$(run_gate_with_body "$REPO_D" "$REPO_D/body.md" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "release-impact is none"; then
  echo "PASS: shippable non-manifest diff with none intent fails"
else
  echo "FAIL: shippable diff with none expected failure; rc=$rc output=$out" >&2
  fail=1
fi

# E: manifest diff with version greater than base passes.
REPO_E="$FIXTURE_ROOT/repo-e"
init_repo "$REPO_E"
write_plugin_json "$REPO_E" "1.0.0"
commit_all "$REPO_E" "base manifests"
git -C "$REPO_E" "${GIT_ID[@]}" checkout -q -b pr-branch
write_plugin_json "$REPO_E" "1.0.1"
commit_all "$REPO_E" "manifest bump"
rc=0
out="$(run_gate_clean "$REPO_E" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "version bumped 1.0.0 -> 1.0.1"; then
  echo "PASS: manifest bump greater than base"
else
  echo "FAIL: manifest bump expected pass; rc=$rc output=$out" >&2
  fail=1
fi

# F: manifest diff with version equal to base fails.
REPO_F="$FIXTURE_ROOT/repo-f"
init_repo "$REPO_F"
write_plugin_json "$REPO_F" "1.0.0"
commit_all "$REPO_F" "base manifests"
git -C "$REPO_F" "${GIT_ID[@]}" checkout -q -b pr-branch
printf '{"version":"1.0.0","description":"changed"}' > "$REPO_F/.codex-plugin/plugin.json"
commit_all "$REPO_F" "manifest edit without bump"
rc=0
out="$(run_gate_clean "$REPO_F" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "plugin version was not incremented"; then
  echo "PASS: manifest edit without bump fails"
else
  echo "FAIL: manifest edit without bump expected failure; rc=$rc output=$out" >&2
  fail=1
fi

# G: manifest versions disagree fails.
REPO_G="$FIXTURE_ROOT/repo-g"
init_repo "$REPO_G"
write_plugin_json "$REPO_G" "1.0.0"
commit_all "$REPO_G" "base manifests"
git -C "$REPO_G" "${GIT_ID[@]}" checkout -q -b pr-branch
printf '{"version":"9.9.9"}' > "$REPO_G/.codex-plugin/plugin.json"
commit_all "$REPO_G" "inconsistent manifest"
rc=0
out="$(run_gate_clean "$REPO_G" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "plugin version occurrences disagree"; then
  echo "PASS: manifest disagreement fails"
else
  echo "FAIL: manifest disagreement expected failure; rc=$rc output=$out" >&2
  fail=1
fi

# H: consumer root with no plugin manifests skips.
REPO_H="$FIXTURE_ROOT/repo-h"
init_repo "$REPO_H"
mkdir -p "$REPO_H/scripts"
printf '#!/usr/bin/env bash\n' > "$REPO_H/scripts/example.sh"
commit_all "$REPO_H" "consumer root base"
git -C "$REPO_H" "${GIT_ID[@]}" checkout -q -b pr-branch
printf 'changed\n' > "$REPO_H/scripts/example.sh"
commit_all "$REPO_H" "consumer script edit"
rc=0
out="$(run_gate_clean "$REPO_H" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "plugin version manifests not found"; then
  echo "PASS: consumer root without plugin manifests skips"
else
  echo "FAIL: consumer root expected skip; rc=$rc output=$out" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
