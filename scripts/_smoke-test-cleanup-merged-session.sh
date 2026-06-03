#!/usr/bin/env bash
# owner: git-workflow-tooling
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/cleanup-merged-session.sh"
[ -x "$HELPER" ] || { echo "FAIL: helper missing or not executable" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-merged-session.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
REAL_GIT="$(command -v git)"
export REAL_GIT
cat > "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${CLEANUP_GIT_FAIL_WORKTREE_REMOVE:-}" = true ]; then
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "worktree" ] && [ "$arg" = "remove" ]; then
      exit 1
    fi
    prev="$arg"
  done
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$STUB_BIN/git"

cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    exit 0
    ;;
  "pr list")
    query_base=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--base" ]; then
        query_base="$arg"
        break
      fi
      prev="$arg"
    done
    if [ -n "$query_base" ] && [ "$query_base" != "${CLEANUP_GH_AVAILABLE_BASE:-main}" ]; then
      exit 0
    fi
    if [ -n "${CLEANUP_GH_HEAD_SHA:-}" ]; then
      printf '{"number":1,"headRefOid":"%s"}\n' "$CLEANUP_GH_HEAD_SHA"
    fi
    exit 0
    ;;
esac
echo "unexpected gh stub call: $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/gh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

run_helper() {
  local cwd="$1" head_sha="$2"
  shift 2
  (
    cd "$cwd"
    PATH="$STUB_BIN:$PATH" ROADMAP_BACKEND=github CLEANUP_GH_HEAD_SHA="$head_sha" bash "$HELPER" "$@"
  )
}

setup_repo() {
  local name="$1"
  local default_branch="${2:-main}"
  local repo="$TMP/$name"
  local origin="$TMP/$name-origin.git"
  git init -q --bare "$origin"
  git --git-dir="$origin" symbolic-ref HEAD "refs/heads/$default_branch"
  git init -q "$repo"
  git -C "$repo" config user.name "Cleanup Test"
  git -C "$repo" config user.email "cleanup@example.com"
  git -C "$repo" checkout -q -b "$default_branch"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin "$default_branch"
  git -C "$repo" remote set-head origin "$default_branch" >/dev/null 2>&1
  printf '%s\n' "$repo"
}

commit_on_branch() {
  local repo="$1" branch="$2" content="$3"
  local base="${4:-main}"
  git -C "$repo" checkout -q -b "$branch" "$base"
  printf '%s\n' "$content" > "$repo/$branch.txt"
  git -C "$repo" add "$branch.txt"
  git -C "$repo" commit -q -m "$branch"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  printf '%s\n' "$haystack" | grep -q "$needle" || fail "$label"
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s\n' "$haystack" | grep -q "$needle"; then
    fail "$label"
  fi
  return 0
}

repo="$(setup_repo protected)"
out="$(run_helper "$repo" "" --branch main --worktree "$repo" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "protected branch exited $rc"
assert_contains "$out" 'cleanup=skipped reason=protected-branch' "protected branch token missing"
pass "protected branch main is refused"

repo="$(setup_repo dirty)"
commit_on_branch "$repo" dirty-branch "dirty"
printf 'worktree change\n' > "$repo/untracked.txt"
out="$(run_helper "$repo" "$(git -C "$repo" rev-parse dirty-branch)" --branch dirty-branch --worktree "$repo" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "dirty worktree exited $rc"
assert_contains "$out" 'cleanup=skipped reason=dirty-worktree' "dirty worktree token missing"
pass "dirty worktree is refused"

repo="$(setup_repo mismatch)"
commit_on_branch "$repo" target-branch "target"
target_sha="$(git -C "$repo" rev-parse target-branch)"
git -C "$repo" checkout -q main
commit_on_branch "$repo" other-branch "other"
git -C "$repo" checkout -q main
linked="$TMP/mismatch-linked"
git -C "$repo" worktree add -q "$linked" other-branch
out="$(run_helper "$repo" "$target_sha" --branch target-branch --worktree "$linked" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "mismatched worktree branch exited $rc"
assert_contains "$out" 'cleanup=skipped reason=worktree-branch-mismatch' "worktree branch mismatch token missing"
git -C "$repo" rev-parse --verify target-branch >/dev/null 2>&1 || fail "mismatched branch was deleted"
[ -d "$linked" ] || fail "mismatched worktree was removed"
pass "target worktree must be on the target branch"

repo="$(setup_repo safe)"
commit_on_branch "$repo" merged-safe "safe"
safe_sha="$(git -C "$repo" rev-parse merged-safe)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff merged-safe -m "merge safe"
git -C "$repo" push -q origin main
linked="$TMP/safe-linked"
git -C "$repo" worktree add -q "$linked" merged-safe
out="$(run_helper "$repo" "$safe_sha" --branch merged-safe --worktree "$linked" 2>&1)" || fail "safe delete helper failed: $out"
assert_contains "$out" 'branch=deleted mode=safe' "safe delete token missing"
git -C "$repo" rev-parse --verify merged-safe >/dev/null 2>&1 && fail "safe branch still exists"
[ ! -d "$linked" ] || fail "safe linked worktree still exists"
pass "merged branch is deleted with branch -d"

repo="$(setup_repo squash)"
commit_on_branch "$repo" squash-branch "squash"
squash_sha="$(git -C "$repo" rev-parse squash-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --squash squash-branch >/dev/null
git -C "$repo" commit -q -m "squash branch"
git -C "$repo" push -q origin main
linked="$TMP/squash-linked"
git -C "$repo" worktree add -q "$linked" squash-branch
out="$(run_helper "$repo" "$squash_sha" --branch squash-branch --worktree "$linked" 2>&1)" || fail "squash delete helper failed: $out"
assert_contains "$out" 'branch=deleted mode=force-squash' "force delete token missing"
git -C "$repo" rev-parse --verify squash-branch >/dev/null 2>&1 && fail "squash branch still exists"
[ ! -d "$linked" ] || fail "squash linked worktree still exists"
pass "squash-merged branch is force-deleted only after provider proof"

repo="$(setup_repo master-default master)"
commit_on_branch "$repo" master-safe "master safe" master
master_safe_sha="$(git -C "$repo" rev-parse master-safe)"
git -C "$repo" checkout -q master
git -C "$repo" merge -q --no-ff master-safe -m "merge master safe"
git -C "$repo" push -q origin master
linked="$TMP/master-safe-linked"
git -C "$repo" worktree add -q "$linked" master-safe
out="$(CLEANUP_GH_AVAILABLE_BASE=master run_helper "$repo" "$master_safe_sha" --branch master-safe --worktree "$linked" 2>&1)" || fail "master-default helper failed: $out"
assert_contains "$out" 'branch=deleted mode=safe' "master default safe delete token missing"
git -C "$repo" rev-parse --verify master-safe >/dev/null 2>&1 && fail "master default branch still exists"
[ ! -d "$linked" ] || fail "master default linked worktree still exists"
pass "remote default branch is used for provider proof and main sync"

repo="$(setup_repo wrong-base)"
commit_on_branch "$repo" release-only "release"
release_sha="$(git -C "$repo" rev-parse release-only)"
git -C "$repo" checkout -q main
linked="$TMP/wrong-base-linked"
git -C "$repo" worktree add -q "$linked" release-only
out="$(CLEANUP_GH_AVAILABLE_BASE=release run_helper "$repo" "$release_sha" --branch release-only --worktree "$linked" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "wrong-base provider proof exited $rc"
assert_contains "$out" 'cleanup=skipped reason=no-merged-pr' "wrong-base proof token missing"
git -C "$repo" rev-parse --verify release-only >/dev/null 2>&1 || fail "wrong-base branch was deleted"
[ -d "$linked" ] || fail "wrong-base linked worktree was removed"
pass "provider proof must target main before force deletion"

repo="$(setup_repo unproven)"
commit_on_branch "$repo" unproven-branch "provider"
provider_sha="$(git -C "$repo" rev-parse unproven-branch)"
printf 'local-only\n' > "$repo/local-only.txt"
git -C "$repo" add local-only.txt
git -C "$repo" commit -q -m "local only"
git -C "$repo" checkout -q main
linked="$TMP/unproven-linked"
git -C "$repo" worktree add -q "$linked" unproven-branch
out="$(run_helper "$repo" "$provider_sha" --branch unproven-branch --worktree "$linked" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "unproven branch exited $rc"
assert_contains "$out" 'cleanup=skipped reason=unproven-local-commits' "unproven local commits token missing"
git -C "$repo" rev-parse --verify unproven-branch >/dev/null 2>&1 || fail "unproven branch was deleted"
[ -d "$linked" ] || fail "unproven linked worktree was removed"
pass "local commits beyond provider head are refused"

repo="$(setup_repo control-dirty)"
commit_on_branch "$repo" control-dirty-branch "control dirty"
control_dirty_sha="$(git -C "$repo" rev-parse control-dirty-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff control-dirty-branch -m "merge control dirty"
git -C "$repo" push -q origin main
linked="$TMP/control-dirty-linked"
git -C "$repo" worktree add -q "$linked" control-dirty-branch
printf 'dirty control\n' > "$repo/control-dirty.txt"
out="$(run_helper "$linked" "$control_dirty_sha" --branch control-dirty-branch --worktree "$linked" --remove-active-worktree 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "dirty control worktree exited $rc"
assert_contains "$out" 'cleanup=skipped reason=control-worktree-dirty' "control dirty token missing: $out"
[ "$(git -C "$linked" symbolic-ref --quiet --short HEAD)" = "control-dirty-branch" ] || fail "target worktree was detached before control dirty refusal"
pass "control worktree preconditions run before target detach"

repo="$(setup_repo active)"
commit_on_branch "$repo" active-branch "active"
active_sha="$(git -C "$repo" rev-parse active-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff active-branch -m "merge active"
git -C "$repo" push -q origin main
linked="$TMP/active-linked"
git -C "$repo" worktree add -q "$linked" active-branch
out="$(run_helper "$linked" "$active_sha" --branch active-branch --worktree "$linked" --remove-active-worktree 2>&1)" || fail "active worktree helper failed: $out"
assert_contains "$out" 'worktree=removed active=true' "active worktree removal token missing"
assert_contains "$out" 'session=terminal reason=active-worktree-removed action=end-or-reopen-session' "active worktree terminal token missing"
[ ! -d "$linked" ] || fail "active worktree directory still exists"
pass "active session worktree removal is terminal and exact"

repo="$(setup_repo active-fail)"
commit_on_branch "$repo" active-fail-branch "active fail"
active_fail_sha="$(git -C "$repo" rev-parse active-fail-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff active-fail-branch -m "merge active fail"
git -C "$repo" push -q origin main
linked="$TMP/active-fail-linked"
git -C "$repo" worktree add -q "$linked" active-fail-branch
out="$(CLEANUP_GIT_FAIL_WORKTREE_REMOVE=true run_helper "$linked" "$active_fail_sha" --branch active-fail-branch --worktree "$linked" --remove-active-worktree 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "failed active removal exited $rc"
assert_contains "$out" 'worktree=kept reason=remove-failed' "failed active removal token missing"
assert_not_contains "$out" 'worktree=removed active=true' "failed active removal claimed removal"
assert_not_contains "$out" 'session=terminal reason=active-worktree-removed action=end-or-reopen-session' "failed active removal emitted terminal token"
[ -d "$linked" ] || fail "failed active worktree directory was removed"
pass "active session terminal tokens emit only after removal succeeds"
