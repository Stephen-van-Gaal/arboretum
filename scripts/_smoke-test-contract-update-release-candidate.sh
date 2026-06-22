#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/dev-contracts/release/update-release-candidate.cli-contract.md.

set -uo pipefail

# Hermetic fixtures (#842): the script-under-test reads its config from
# RELEASE_CANDIDATE_* env vars. In the nightly workflow the `Capture preflight
# base` step exports RELEASE_CANDIDATE_BASE_SHA=<real main HEAD> into $GITHUB_ENV,
# which leaks into this test and makes update-release-candidate.sh resolve a base
# commit that does not exist in the /tmp fixture repos → exit 2 on every case
# (passed locally, failed only in the nightly). Clear the whole namespace up front
# so the test controls exactly what each invocation sees; cases that need a value
# (e.g. pinned-base) pass it explicitly per run.
unset RELEASE_CANDIDATE_BASE_SHA RELEASE_CANDIDATE_BRANCH RELEASE_CANDIDATE_TITLE \
  RELEASE_CANDIDATE_STALE_DAYS RELEASE_CANDIDATE_BOT_AUTHOR RELEASE_CANDIDATE_BOT_EMAIL \
  RELEASE_CANDIDATE_PREPARE RELEASE_CANDIDATE_GH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/dev-tools/release/update-release-candidate.sh"
CONTRACT="$ROOT/docs/dev-contracts/release/update-release-candidate.cli-contract.md"
GIT_ID=(-c user.email=t@t -c user.name=t)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

# Diagnostic surfacing (#839): truncate the reused, non-$TMP capture paths up
# front so a pre-invocation assertion failure (e.g. the contract-doc checks
# below, which run before any script call) can never replay a prior run's
# leftover output. They are overwritten by each real invocation thereafter.
# FAILURES_LOG accumulates each failing case's capture at the moment it fails, so
# the offline artifact carries the FAILED case's output even though later cases
# overwrite /tmp/update-rc.* (the workflow gathers this file, not the volatile
# /tmp captures) — see review #840.
FAILURES_LOG=/tmp/update-rc-failures.log
: >/tmp/update-rc.out
: >/tmp/update-rc.err
: >"$FAILURES_LOG"

# Every real-execution case redirects the script's
# stdout/stderr to these reused capture paths and is checked immediately after.
# On a failed assertion, replay them so the script's real precondition diagnostic
# (e.g. "not a git worktree" vs "provider command not found") reaches the
# already-verbose-in-CI Actions log instead of being silently discarded, AND
# snapshot them into FAILURES_LOG before a later case can overwrite them. Passing
# runs call this never, so green stays quiet. Manual side-effect branches that set
# fail=1 directly must call this too (review #840), else their helper output is
# swallowed.
dump_script_capture() {
  local label="${1:-unnamed assertion}"
  local cap
  for cap in /tmp/update-rc.out /tmp/update-rc.err; do
    if [ -s "$cap" ]; then
      echo "  --- ${cap} (captured script output) ---" >&2
      sed 's/^/  | /' "$cap" >&2
      { echo "=== FAILED: ${label} — ${cap} ==="; cat "$cap"; echo; } >>"$FAILURES_LOG"
    fi
  done
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name expected '$expected' got '$actual'" >&2
    dump_script_capture "$name"
    fail=1
  fi
}

contains() {
  local name="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    dump_script_capture "$name"
    fail=1
  fi
}

[ -f "$CONTRACT" ] || { echo "FAIL: contract not found at $CONTRACT" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

contains "contract names generated marker" 'arboretum-release-candidate:bot-owned' "$CONTRACT"
contains "contract forbids auto-merge" 'It does not merge' "$CONTRACT"
contains "contract names bot email" 'RELEASE_CANDIDATE_BOT_EMAIL' "$CONTRACT"

make_fixture() {
  local name="$1" repo origin
  repo="$TMP/$name/repo"
  origin="$TMP/$name/origin.git"
  mkdir -p "$TMP/$name"
  git init -q --bare "$origin"
  git init -q "$repo"
  git -C "$repo" "${GIT_ID[@]}" checkout -q -b main
  mkdir -p "$repo/.claude-plugin" "$repo/.codex-plugin" "$repo/dev-tools/release"
  printf '{"version":"0.24.7"}\n' >"$repo/.claude-plugin/plugin.json"
  printf '{"version":"0.24.7","plugins":[{"version":"0.24.7"}]}\n' >"$repo/.claude-plugin/marketplace.json"
  printf '{"version":"0.24.7"}\n' >"$repo/.codex-plugin/plugin.json"
  git -C "$repo" "${GIT_ID[@]}" add .claude-plugin .codex-plugin
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  printf '%s\n' "$repo"
}

write_prepare_stub() {
  local repo="$1"
  cat >"$repo/dev-tools/release/prepare-stub.sh" <<'PREPARE'
#!/usr/bin/env bash
set -euo pipefail
mode="${PREPARE_MODE:?}"
case "$mode" in
  none)
    echo "release-ready=no"
    exit 0
    ;;
  ready)
    python3 - "${REPO_ROOT:?}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
updates = [
    root / ".claude-plugin" / "plugin.json",
    root / ".claude-plugin" / "marketplace.json",
    root / ".codex-plugin" / "plugin.json",
]
for path in updates:
    data = json.loads(path.read_text(encoding="utf-8"))
    data["version"] = "0.25.0"
    if path.name == "marketplace.json":
        data["plugins"][0]["version"] = "0.25.0"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
(root / "docs" / "releases").mkdir(parents=True, exist_ok=True)
(root / "docs" / "releases" / "v0.25.0.md").write_text("# Arboretum v0.25.0\n", encoding="utf-8")
(root / "CHANGELOG.md").write_text("# Changelog\n\n- [v0.25.0](docs/releases/v0.25.0.md) - fixture.\n", encoding="utf-8")
PY
    echo "release-impact=patch"
    echo "checkpoint-version=0.24.7"
    echo "next-version=0.25.0"
    echo "included-count=1"
    echo "release-ready=yes"
    echo "release-notes=docs/releases/v0.25.0.md"
    ;;
  *)
    echo "unexpected PREPARE_MODE=$mode" >&2
    exit 9
    ;;
esac
PREPARE
  chmod +x "$repo/dev-tools/release/prepare-stub.sh"
  git -C "$repo" "${GIT_ID[@]}" add dev-tools/release/prepare-stub.sh
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "add prepare stub"
  git -C "$repo" push -q origin main
}

make_gh_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  "pr list --state open --head automation/release-candidate --json number,body,createdAt,headRefOid,headRepositoryOwner,isCrossRepository --limit 20")
    cat "${GH_PR_LIST:?}"
    ;;
  pr\ create*) echo "https://github.example/release-pr" ;;
  pr\ edit*) exit 0 ;;
  pr\ close*) exit 0 ;;
  pr\ comment*) exit 0 ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
  chmod +x "$dir/gh"
}

make_gh_poison() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
echo "poison gh should not be used" >&2
exit 42
GH
  chmod +x "$dir/gh"
}

run_helper() {
  local repo="$1" pr_json="$2" prepare_mode="$3" log="$4" extra_env="${5:-}"
  local gh_dir
  gh_dir="$TMP/gh-bin-$(basename "$(dirname "$repo")")"
  make_gh_stub "$gh_dir"
  write_prepare_stub "$repo"
  printf '%s\n' "$pr_json" >"$TMP/pr.json"
  GH_LOG="$log" GH_PR_LIST="$TMP/pr.json" PREPARE_MODE="$prepare_mode" REPO_ROOT="$repo" RELEASE_CANDIDATE_PREPARE="$repo/dev-tools/release/prepare-stub.sh" RELEASE_CANDIDATE_GH="$gh_dir/gh" env $extra_env bash "$SCRIPT"
}

INVALID="$(make_fixture invalid)"
write_prepare_stub "$INVALID"
printf '[]\n' >"$TMP/pr-invalid.json"
rc=0
GH_LOG="$TMP/gh-invalid.log" GH_PR_LIST="$TMP/pr-invalid.json" PATH="$TMP/no-gh:$PATH" PREPARE_MODE=none REPO_ROOT="$INVALID" RELEASE_CANDIDATE_PREPARE="$INVALID/dev-tools/release/prepare-stub.sh" RELEASE_CANDIDATE_STALE_DAYS=abc bash "$SCRIPT" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "invalid stale days exits 2" "2" "$rc"
contains "invalid stale days diagnostic" 'STALE_DAYS must be a non-negative integer' /tmp/update-rc.err

NON_GIT="$TMP/non-git-root"
mkdir -p "$NON_GIT"
make_gh_stub "$TMP/gh-non-git"
printf '[]\n' >"$TMP/pr-non-git.json"
rc=0
GH_LOG="$TMP/gh-non-git.log" GH_PR_LIST="$TMP/pr-non-git.json" RELEASE_CANDIDATE_GH="$TMP/gh-non-git/gh" REPO_ROOT="$NON_GIT" bash "$SCRIPT" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "non-git repo root exits 2" "2" "$rc"
contains "non-git repo root diagnostic" 'not a git worktree' /tmp/update-rc.err

DEFAULT_ROOT="$(make_fixture default-root)"
write_prepare_stub "$DEFAULT_ROOT"
make_gh_stub "$TMP/gh-default-root"
printf '[]\n' >"$TMP/pr-default-root.json"
rc=0
(
  cd "$DEFAULT_ROOT" || exit 99
  GH_LOG="$TMP/gh-default-root.log" GH_PR_LIST="$TMP/pr-default-root.json" PREPARE_MODE=none RELEASE_CANDIDATE_PREPARE="$DEFAULT_ROOT/dev-tools/release/prepare-stub.sh" RELEASE_CANDIDATE_GH="$TMP/gh-default-root/gh" bash "$SCRIPT"
) >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "default repo root exits 0" "0" "$rc"

PINNED_PROVIDER="$(make_fixture pinned-provider)"
write_prepare_stub "$PINNED_PROVIDER"
make_gh_stub "$TMP/gh-pinned-provider"
make_gh_poison "$TMP/gh-poison"
printf '[]\n' >"$TMP/pr-pinned-provider.json"
rc=0
(
  cd "$PINNED_PROVIDER" || exit 99
  GH_LOG="$TMP/gh-pinned-provider.log" GH_PR_LIST="$TMP/pr-pinned-provider.json" PATH="$TMP/gh-poison:$PATH" PREPARE_MODE=none RELEASE_CANDIDATE_PREPARE="$PINNED_PROVIDER/dev-tools/release/prepare-stub.sh" RELEASE_CANDIDATE_GH="$TMP/gh-pinned-provider/gh" bash "$SCRIPT"
) >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "provider stub is pinned outside PATH" "0" "$rc"
contains "pinned provider used gh stub" 'pr list' "$TMP/gh-pinned-provider.log"

HUMAN_PR="$(make_fixture human-pr)"
rc=0
run_helper "$HUMAN_PR" '[{"number":7,"body":"human body","createdAt":"2026-06-01T00:00:00Z","headRefOid":"abc","isCrossRepository":false}]' ready "$TMP/gh-human-pr.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "human-owned PR exits 1" "1" "$rc"
contains "human-owned PR diagnostic" 'lacks generated marker' /tmp/update-rc.err

NO_PENDING="$(make_fixture no-pending)"
rc=0
run_helper "$NO_PENDING" '[]' none "$TMP/gh-no-pending.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "no pending with no PR exits 0" "0" "$rc"
if grep -q 'pr create' "$TMP/gh-no-pending.log"; then
  echo "FAIL: no-pending run should not create PR" >&2
  dump_script_capture "no-pending run should not create PR"
  fail=1
else
  echo "PASS: no-pending run does not create PR"
fi

CREATE="$(make_fixture create)"
rc=0
run_helper "$CREATE" '[]' ready "$TMP/gh-create.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "pending release creates PR" "0" "$rc"
contains "create call logged" 'pr create' "$TMP/gh-create.log"
if git -C "$CREATE" show-ref --verify --quiet refs/heads/automation/release-candidate \
   && git -C "$CREATE" log -1 --format=%s automation/release-candidate | grep -q 'chore: prepare release package v0.25.0' \
   && git -C "$CREATE" ls-remote --exit-code --heads origin automation/release-candidate >/dev/null 2>&1; then
  echo "PASS: release branch committed and pushed"
else
  echo "FAIL: release branch was not committed and pushed" >&2
  dump_script_capture "release branch was not committed and pushed"
  fail=1
fi
check "release branch commit uses bot identity" \
  "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" \
  "$(git -C "$CREATE" log -1 --format='%an <%ae>' automation/release-candidate)"

UPDATE="$(make_fixture update)"
rc=0
run_helper "$UPDATE" '[{"number":8,"body":"<!-- arboretum-release-candidate:bot-owned -->","createdAt":"2000-01-01T00:00:00Z","headRefOid":"abc","isCrossRepository":false}]' ready "$TMP/gh-update.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "existing bot PR updates" "0" "$rc"
contains "edit call logged" 'pr edit 8 --title Release package: next Arboretum release --body-file' "$TMP/gh-update.log"
contains "stale comment logged" 'pr comment 8 --body' "$TMP/gh-update.log"

FORK_ONLY="$(make_fixture fork-only)"
rc=0
run_helper "$FORK_ONLY" '[{"number":10,"body":"<!-- arboretum-release-candidate:bot-owned -->","createdAt":"2026-06-01T00:00:00Z","headRefOid":"abc","isCrossRepository":true}]' ready "$TMP/gh-fork-only.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "fork-owned PR ignored" "0" "$rc"
contains "fork-owned PR creates same-repo PR" 'pr create' "$TMP/gh-fork-only.log"

PINNED_BASE="$(make_fixture pinned-base)"
write_prepare_stub "$PINNED_BASE"
pinned_sha="$(git -C "$PINNED_BASE" rev-parse HEAD)"
printf 'remote advance\n' >"$PINNED_BASE/remote-advance.txt"
git -C "$PINNED_BASE" "${GIT_ID[@]}" add remote-advance.txt
git -C "$PINNED_BASE" "${GIT_ID[@]}" commit -q -m "remote advance"
git -C "$PINNED_BASE" push -q origin main
git -C "$PINNED_BASE" reset -q --hard "$pinned_sha"
rc=0
run_helper "$PINNED_BASE" '[]' ready "$TMP/gh-pinned-base.log" "RELEASE_CANDIDATE_BASE_SHA=$pinned_sha" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "pinned base creates PR" "0" "$rc"
if [ "$(git -C "$PINNED_BASE" rev-parse automation/release-candidate^)" = "$pinned_sha" ] \
   && ! git -C "$PINNED_BASE" ls-tree -r --name-only automation/release-candidate | grep -qx 'remote-advance.txt'; then
  echo "PASS: release branch uses preflighted base"
else
  echo "FAIL: release branch did not use preflighted base" >&2
  dump_script_capture "release branch did not use preflighted base"
  fail=1
fi

HUMAN_BRANCH="$(make_fixture human-branch)"
git -C "$HUMAN_BRANCH" "${GIT_ID[@]}" checkout -q -b automation/release-candidate
printf 'human\n' >"$HUMAN_BRANCH/human.txt"
git -C "$HUMAN_BRANCH" -c user.email=h@h -c user.name=Human add human.txt
git -C "$HUMAN_BRANCH" -c user.email=h@h -c user.name=Human commit -q -m "human edit"
git -C "$HUMAN_BRANCH" push -q origin automation/release-candidate
git -C "$HUMAN_BRANCH" checkout -q main
rc=0
run_helper "$HUMAN_BRANCH" '[{"number":9,"body":"<!-- arboretum-release-candidate:bot-owned -->","createdAt":"2026-06-01T00:00:00Z","headRefOid":"abc","isCrossRepository":false}]' ready "$TMP/gh-human-branch.log" >/tmp/update-rc.out 2>/tmp/update-rc.err || rc=$?
check "human branch commit exits 1" "1" "$rc"
contains "human branch diagnostic" 'contains non-bot commits' /tmp/update-rc.err

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi

echo "SMOKE TEST PASSED"
