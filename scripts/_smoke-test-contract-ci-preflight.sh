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

# Fixture health-check.sh emits the three-level severity exit code S2 (#641)
# introduced: 0 = clean, 1 = >=1 blocking finding, 2 = advisory-only findings.
# Check-7 built-state drift is classified advisory (S1/S2), so the `drift` state
# emits exit 2 while still printing the real `run with --reconcile to update`
# marker text — proving the consumer reads the exit code, not the marker.
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
# Consumer no longer calls --reconcile for health drift; accept and ignore the
# flag for robustness.
if [ "${1:-}" = "--reconcile" ]; then
  shift
fi
root="${1:-$(pwd)}"
state="$(cat "$root/health_state")"
case "$state" in
  clean)
    echo "HEALTHY: No drift detected across 9 checks."
    exit 0
    ;;
  drift)
    # Advisory: Check-7 built-state drift. Real S2 advise() still prints the
    # reconcile marker; severity is carried by the exit code, not the text.
    echo "  ⚠ example.spec.md: drift detected (scripts/example.sh modified after spec's last commit abc123) — run with --reconcile to update"
    echo "ADVISORIES: 1 advisory finding (⚠) across 9 checks; no blocking drift."
    exit 2
    ;;
  recorded)
    echo "  ⚠ example.spec.md: status=stale — drift recorded; run /consolidate to reconcile"
    echo "ADVISORIES: 1 advisory finding (⚠) across 9 checks; no blocking drift."
    exit 2
    ;;
  blocking)
    echo "  ✗ Check 3: docs/specs/example.spec.md references missing file scripts/ghost.sh"
    echo "DRIFT DETECTED: 1 blocking finding (✗) across 9 checks."
    exit 1
    ;;
  crash)
    echo "health-check: unexpected internal error" >&2
    exit 3
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

# ── Contract shape (retained surfaces) ──────────────────────────────────
contains "contract names safe repairs" "Safe repairs" "$CONTRACT"
contains "contract names release scope" "Release scope" "$CONTRACT"
contains "contract names automated commit modes" "Automated commit modes" "$CONTRACT"
contains "contract names continue-after-repair" "continue-after-repair" "$CONTRACT"
contains "contract includes manual PR diagram" "Manual PR automation" "$CONTRACT"
contains "contract includes nightly diagram" "Nightly automation" "$CONTRACT"

# ── Contract shape (new exit-code severity model) ───────────────────────
contains "contract documents three-level exit codes" "Exit codes" "$CONTRACT"
contains "contract documents health-check severity read" "Health-check severity" "$CONTRACT"
contains "contract names advisory severity" "advisory" "$CONTRACT"
# The Branch-context behaviour section is gone (history in the changelog and a
# related-design filename legitimately survives, so assert on the section
# heading, not the bare term).
rejects "contract drops Branch context section" "### Branch context" "$CONTRACT"
rejects "contract drops the Environment/default-branch section" "### Environment" "$CONTRACT"
# The script carries no branch-context machinery and no drift-marker string-match.
rejects "script drops branch-context machinery" "branch-context" "$SCRIPT"
rejects "script no longer string-matches the drift marker" "run with --reconcile to update" "$SCRIPT"
rejects "script does not use fixed /tmp reconcile output" "/tmp/ci-preflight-health-reconcile.out" "$SCRIPT"
rejects "script avoids Bash-4-only mapfile" "mapfile" "$SCRIPT"

# ── Health-check severity, read from the exit code ──────────────────────

# clean → exit 0
clean="$(make_fixture clean clean clean)"
clean_out="$TMP/clean.out"
rc="$(run_preflight "$clean_out" --root "$clean")"
check "clean fixture exits 0" "0" "$rc"
contains "clean fixture prints pass banner" "PREFLIGHT OK" "$clean_out"

# advisory drift (exit 2) → surfaces, does NOT block, does NOT mutate the spec.
# Runs on the default branch (no feature branch) to prove severity is intrinsic
# to the finding, not derived from branch context.
advisory="$(make_fixture advisory drift clean)"
advisory_out="$TMP/advisory.out"
rc="$(run_preflight "$advisory_out" --root "$advisory")"
check "advisory drift exits 0 (non-blocking) on default branch" "0" "$rc"
contains "advisory drift is surfaced" "ADVISORY" "$advisory_out"
contains "advisory drift names the spec" "example.spec.md" "$advisory_out"
contains "advisory drift leaves spec active" "status: active" "$advisory/docs/specs/example.spec.md"

# blocking finding (exit 1) → blocks
blocking="$(make_fixture blocking blocking clean)"
blocking_out="$TMP/blocking.out"
rc="$(run_preflight "$blocking_out" --root "$blocking")"
check "blocking health finding exits 1" "1" "$rc"
contains "blocking finding names blocker" "blocking health-check findings" "$blocking_out"

# unexpected exit code (e.g. 3, a crash) → treated as blocking (fail closed)
crash="$(make_fixture crash crash clean)"
crash_out="$TMP/crash.out"
rc="$(run_preflight "$crash_out" --root "$crash")"
check "unexpected health-check exit code blocks (fail closed)" "1" "$rc"
contains "unexpected exit code is reported" "exited 3" "$crash_out"

# recorded stale (advisory exit 2) → does not block
recorded="$(make_fixture recorded recorded clean)"
recorded_out="$TMP/recorded.out"
rc="$(run_preflight "$recorded_out" --root "$recorded")"
check "recorded stale drift does not block" "0" "$rc"

# relative --root still resolves the health script (advisory drift)
relative_root="$(make_fixture relative-root drift clean)"
relative_out="$TMP/relative-root.out"
rc="$(run_preflight_from "$(dirname "$relative_root")" "$relative_out" --root "$(basename "$relative_root")")"
check "relative --root exits 0 on advisory drift" "0" "$rc"
contains "relative --root does not skip health script" "ADVISORY" "$relative_out"

# ── Coverage-manifest drift: the retained safe-repair path ──────────────

# read-only (no --apply-safe-repairs) → blocks
cov_readonly="$(make_fixture cov-readonly clean drift)"
cov_readonly_out="$TMP/cov-readonly.out"
rc="$(run_preflight "$cov_readonly_out" --root "$cov_readonly")"
check "coverage drift read-only exits 1" "1" "$rc"
contains "coverage drift read-only names blocker" "contract coverage manifest drift" "$cov_readonly_out"

# --apply-safe-repairs (default commit mode none) → reviewable diff, exit 1
cov_repair="$(make_fixture cov-repair clean drift)"
cov_repair_out="$TMP/cov-repair.out"
rc="$(run_preflight "$cov_repair_out" --root "$cov_repair" --apply-safe-repairs)"
check "coverage repair exits 1 for reviewable diff" "1" "$rc"
contains "coverage repair reports changed paths" "Repair changed paths" "$cov_repair_out"
if [ -n "$(git -C "$cov_repair" status --short)" ]; then
  echo "PASS: coverage repair leaves reviewable diff"
else
  echo "FAIL: coverage repair should leave a reviewable diff" >&2
  fail=1
fi

# --apply-safe-repairs --continue-after-repair → exit 0, marks fresh
cov_continue="$(make_fixture cov-continue clean drift)"
cov_continue_out="$TMP/cov-continue.out"
rc="$(run_preflight "$cov_continue_out" --root "$cov_continue" --apply-safe-repairs --continue-after-repair)"
check "coverage repair continue exits 0" "0" "$rc"
check "coverage repair marks fresh" "clean" "$(cat "$cov_continue/coverage_state")"

# same-branch repair commit (via coverage drift)
cov_commit="$(make_fixture cov-commit clean drift)"
cov_commit_out="$TMP/cov-commit.out"
rc="$(run_preflight "$cov_commit_out" --root "$cov_commit" --apply-safe-repairs --repair-commit-mode same-branch)"
check "same-branch repair commit exits 1" "1" "$rc"
check "same-branch repair commit message" "chore: repair CI preflight blockers" "$(git -C "$cov_commit" log -1 --format=%s)"
check "same-branch repair leaves tree clean" "" "$(git -C "$cov_commit" status --short)"
contains "same-branch repair reports commit" "PREFLIGHT REPAIR COMMITTED" "$cov_commit_out"

# repair-pr mode (via coverage drift)
repair_pr="$(make_fixture repair-pr clean drift)"
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

# human-owned repair PR → ownership refusal (via coverage drift)
human_repair_pr="$(make_fixture repair-pr-human clean drift)"
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

# ── Release scope ───────────────────────────────────────────────────────
release="$(make_fixture release clean clean 1)"
release_out="$TMP/release.out"
rc="$(run_preflight "$release_out" --root "$release" --scope release)"
check "release-scope blocker exits 1" "1" "$rc"
contains "release blocker reported" "Release blocker" "$release_out"

exit "$fail"
