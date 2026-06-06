#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/contracts/ci-preflight.cli-contract.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/ci-preflight.sh"
CONTRACT="$ROOT/docs/contracts/ci-preflight.cli-contract.md"
GIT_ID=(-c user.email=t@t -c user.name=t)
TMP="$(mktemp -d)"
fail=0

trap 'rm -rf "$TMP"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name expected '$expected' got '$actual'" >&2
    fail=1
  fi
}

contains() {
  local name="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    fail=1
  fi
}

rejects() {
  local name="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then
    echo "FAIL: $name" >&2
    fail=1
  else
    echo "PASS: $name"
  fi
}

run_preflight() {
  local outfile="$1"
  shift
  local rc=0
  bash "$SCRIPT" "$@" >"$outfile" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

run_preflight_from() {
  local cwd="$1" outfile="$2"
  shift 2
  local rc=0
  (cd "$cwd" && bash "$SCRIPT" "$@" >"$outfile" 2>&1) || rc=$?
  printf '%s\n' "$rc"
}

make_gh_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  pr\ list*) printf '%s\n' "${GH_PR_LIST_JSON:-[]}" ;;
  pr\ create*) echo "https://github.example/repair-pr" ;;
  pr\ edit*) exit 0 ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
  chmod +x "$dir/gh"
}

make_fixture() {
  local name="$1" health_state="$2" coverage_state="$3" release_blocker="${4:-0}"
  local repo="$TMP/$name/repo"
  local origin="$TMP/$name/origin.git"

  mkdir -p "$TMP/$name"
  git init -q --bare "$origin"
  git init -q "$repo"
  git -C "$repo" "${GIT_ID[@]}" checkout -q -b main
  mkdir -p "$repo/scripts" "$repo/docs/specs" "$repo/docs/contracts"

  printf '%s\n' "$health_state" >"$repo/health_state"
  printf '%s\n' "$coverage_state" >"$repo/coverage_state"
  if [ "$release_blocker" = "1" ]; then
    : >"$repo/release_blocker"
  fi

  cat >"$repo/docs/specs/example.spec.md" <<'SPEC'
---
status: active
---

# Example Spec
SPEC
  cat >"$repo/docs/REGISTER.md" <<'REGISTER'
| Spec | Status | Owner | Owns |
|---|---|---|---|
| example.spec.md | active | example | scripts/example.sh |
REGISTER
  printf '# Governance-script contract coverage\n' >"$repo/docs/contracts/_coverage.md"

  cat >"$repo/scripts/health-check.sh" <<'HEALTH'
#!/usr/bin/env bash
set -uo pipefail
reconcile=0
if [ "${1:-}" = "--reconcile" ]; then
  reconcile=1
  shift
fi
root="${1:-$(pwd)}"
state_file="$root/health_state"
state="$(cat "$state_file")"
case "$state" in
  clean)
    echo "HEALTHY: No drift detected across 9 checks."
    exit 0
    ;;
  recorded)
    echo "  ✗ example.spec.md: status=stale — drift recorded; run /consolidate to reconcile"
    exit 1
    ;;
  drift)
    if [ "$reconcile" -eq 1 ]; then
      printf '%s\n' recorded >"$state_file"
      python3 - "$root/docs/specs/example.spec.md" "$root/docs/REGISTER.md" <<'PY'
from pathlib import Path
import sys
for arg in sys.argv[1:]:
    path = Path(arg)
    path.write_text(path.read_text().replace("active", "stale"), encoding="utf-8")
PY
      echo "  ✗ example.spec.md: flipped active -> stale (drift: scripts/example.sh modified after spec)"
      exit 1
    fi
    echo "  ✗ example.spec.md: drift detected (scripts/example.sh modified after spec's last commit abc123) — run with --reconcile to update"
    exit 1
    ;;
esac
echo "unexpected health state: $state" >&2
exit 9
HEALTH
  chmod +x "$repo/scripts/health-check.sh"

  cat >"$repo/scripts/validate-coverage-manifest.sh" <<'COVERAGE'
#!/usr/bin/env bash
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="$(cat "$root/coverage_state")"
if [ "$state" = "drift" ]; then
  echo "COVERAGE-MANIFEST-DRIFT: docs/contracts/_coverage.md differs from a fresh generate-coverage.sh run" >&2
  exit 1
fi
echo "coverage manifest fresh"
exit 0
COVERAGE
  chmod +x "$repo/scripts/validate-coverage-manifest.sh"

  cat >"$repo/scripts/generate-coverage.sh" <<'GENERATE'
#!/usr/bin/env bash
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' clean >"$root/coverage_state"
printf '# Governance-script contract coverage\n\nfresh\n' >"$root/docs/contracts/_coverage.md"
GENERATE
  chmod +x "$repo/scripts/generate-coverage.sh"

  cat >"$repo/scripts/_smoke-test-nightly-release-workflow.sh" <<'NIGHTLY'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$root/release_blocker" ]; then
  echo "release workflow blocker" >&2
  exit 1
fi
exit 0
NIGHTLY
  chmod +x "$repo/scripts/_smoke-test-nightly-release-workflow.sh"

  cat >"$repo/scripts/_smoke-test-contract-update-release-candidate.sh" <<'UPDATE'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$root/release_blocker" ]; then
  echo "release update blocker" >&2
  exit 1
fi
exit 0
UPDATE
  chmod +x "$repo/scripts/_smoke-test-contract-update-release-candidate.sh"

  git -C "$repo" "${GIT_ID[@]}" add .
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  printf '%s\n' "$repo"
}

[ -f "$CONTRACT" ] || { echo "FAIL: contract missing: $CONTRACT" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "FAIL: script missing: $SCRIPT" >&2; exit 1; }

contains "contract names safe repairs" "Safe repairs" "$CONTRACT"
contains "contract names release scope" "Release scope" "$CONTRACT"
contains "contract names automated commit modes" "Automated commit modes" "$CONTRACT"
contains "contract names continue-after-repair" "continue-after-repair" "$CONTRACT"
contains "contract includes manual PR diagram" "Manual PR automation" "$CONTRACT"
contains "contract includes nightly diagram" "Nightly automation" "$CONTRACT"
rejects "script does not use fixed /tmp reconcile output" "/tmp/ci-preflight-health-reconcile.out" "$SCRIPT"
rejects "script avoids Bash-4-only mapfile" "mapfile" "$SCRIPT"

clean="$(make_fixture clean clean clean)"
clean_out="$TMP/clean.out"
rc="$(run_preflight "$clean_out" --root "$clean")"
check "clean fixture exits 0" "0" "$rc"
contains "clean fixture prints pass banner" "PREFLIGHT OK" "$clean_out"

recorded="$(make_fixture recorded recorded clean)"
recorded_out="$TMP/recorded.out"
rc="$(run_preflight "$recorded_out" --root "$recorded")"
check "recorded stale drift does not block" "0" "$rc"

relative_root="$(make_fixture relative-root drift clean)"
relative_out="$TMP/relative-root.out"
rc="$(run_preflight_from "$(dirname "$relative_root")" "$relative_out" --root "$(basename "$relative_root")")"
check "relative --root detects health drift" "1" "$rc"
contains "relative --root does not skip health script" "unrecorded health-check drift" "$relative_out"

drift_readonly="$(make_fixture drift-readonly drift clean)"
readonly_out="$TMP/drift-readonly.out"
rc="$(run_preflight "$readonly_out" --root "$drift_readonly")"
check "drift read-only exits 1" "1" "$rc"
contains "drift read-only names blocker" "unrecorded health-check drift" "$readonly_out"
contains "drift read-only leaves spec active" "status: active" "$drift_readonly/docs/specs/example.spec.md"

drift_repair="$(make_fixture drift-repair drift clean)"
repair_out="$TMP/drift-repair.out"
rc="$(run_preflight "$repair_out" --root "$drift_repair" --apply-safe-repairs)"
check "drift repair exits 1 for reviewable diff" "1" "$rc"
contains "drift repair flips spec stale" "status: stale" "$drift_repair/docs/specs/example.spec.md"
contains "drift repair reports changed paths" "Repair changed paths" "$repair_out"
if [ -n "$(git -C "$drift_repair" status --short)" ]; then
  echo "PASS: drift repair leaves reviewable diff"
else
  echo "FAIL: drift repair should leave a reviewable diff" >&2
  fail=1
fi

drift_continue="$(make_fixture drift-continue drift clean)"
continue_out="$TMP/drift-continue.out"
rc="$(run_preflight "$continue_out" --root "$drift_continue" --apply-safe-repairs --continue-after-repair)"
check "drift repair continue exits 0" "0" "$rc"

drift_commit="$(make_fixture drift-commit drift clean)"
commit_out="$TMP/drift-commit.out"
rc="$(run_preflight "$commit_out" --root "$drift_commit" --apply-safe-repairs --repair-commit-mode same-branch)"
check "same-branch repair commit exits 1" "1" "$rc"
check "same-branch repair commit message" "chore: repair CI preflight blockers" "$(git -C "$drift_commit" log -1 --format=%s)"
check "same-branch repair leaves tree clean" "" "$(git -C "$drift_commit" status --short)"
contains "same-branch repair reports commit" "PREFLIGHT REPAIR COMMITTED" "$commit_out"

repair_pr="$(make_fixture repair-pr drift clean)"
gh_dir="$TMP/gh"
make_gh_stub "$gh_dir"
repair_pr_out="$TMP/repair-pr.out"
rc="$(GH_LOG="$TMP/gh.log" run_preflight "$repair_pr_out" --root "$repair_pr" --apply-safe-repairs --repair-commit-mode repair-pr --repair-branch automation/ci-preflight-repair --gh-cmd "$gh_dir/gh")"
check "repair-pr mode exits 1" "1" "$rc"
if git -C "$repair_pr" ls-remote --exit-code --heads origin automation/ci-preflight-repair >/dev/null 2>&1; then
  echo "PASS: repair-pr branch pushed"
else
  echo "FAIL: repair-pr branch was not pushed" >&2
  fail=1
fi
contains "repair-pr creates PR" "pr create" "$TMP/gh.log"

human_repair_pr="$(make_fixture repair-pr-human drift clean)"
git -C "$human_repair_pr" push -q origin HEAD:refs/heads/automation/ci-preflight-repair
human_before="$(git -C "$human_repair_pr" ls-remote --heads origin automation/ci-preflight-repair | awk '{ print $1 }')"
human_out="$TMP/repair-pr-human.out"
rc="$(
  GH_LOG="$TMP/gh-human.log" \
  GH_PR_LIST_JSON='[{"number":42,"body":"human-owned","isCrossRepository":false}]' \
    run_preflight "$human_out" --root "$human_repair_pr" --apply-safe-repairs --repair-commit-mode repair-pr --repair-branch automation/ci-preflight-repair --gh-cmd "$gh_dir/gh"
)"
human_after="$(git -C "$human_repair_pr" ls-remote --heads origin automation/ci-preflight-repair | awk '{ print $1 }')"
check "human-owned repair PR exits 1" "1" "$rc"
check "human-owned repair PR leaves remote branch unchanged" "$human_before" "$human_after"
contains "human-owned repair PR reports ownership refusal" "human-owned repair PR" "$human_out"

coverage="$(make_fixture coverage clean drift)"
coverage_out="$TMP/coverage.out"
rc="$(run_preflight "$coverage_out" --root "$coverage" --apply-safe-repairs --continue-after-repair)"
check "coverage repair exits 0 with continue" "0" "$rc"
check "coverage repair marks fresh" "clean" "$(cat "$coverage/coverage_state")"

release="$(make_fixture release clean clean 1)"
release_out="$TMP/release.out"
rc="$(run_preflight "$release_out" --root "$release" --scope release)"
check "release-scope blocker exits 1" "1" "$rc"
contains "release blocker reported" "Release blocker" "$release_out"

exit "$fail"
