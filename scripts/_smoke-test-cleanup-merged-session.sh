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

# --- Task 1: mode parsing ---
repo="$(setup_repo mode-exclusive)"
commit_on_branch "$repo" mode-branch "mode"
mode_sha="$(git -C "$repo" rev-parse mode-branch)"
git -C "$repo" checkout -q main
out="$(run_helper "$repo" "$mode_sha" --branch mode-branch --worktree "$repo" --plan --execute 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "plan+execute together exited $rc (want 2)"
assert_contains "$out" 'cleanup=skipped reason=mode-conflict' "mode-conflict should emit a setup-error token"
assert_not_contains "$out" 'plan=blocked' "exit-2 setup error must not masquerade as plan=blocked"
pass "--plan and --execute together are rejected"

# --- Task 2: read-only --plan emission ---
# --plan ready (safe, merge-commit) and proves no mutation
repo="$(setup_repo plan-safe)"
commit_on_branch "$repo" plan-safe-branch "plan safe"
plan_safe_sha="$(git -C "$repo" rev-parse plan-safe-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff plan-safe-branch -m "merge plan safe"
git -C "$repo" push -q origin main
linked="$TMP/plan-safe-linked"
git -C "$repo" worktree add -q "$linked" plan-safe-branch
out="$(run_helper "$repo" "$plan_safe_sha" --branch plan-safe-branch --worktree "$linked" --plan 2>&1)" || fail "plan-safe helper failed: $out"
assert_contains "$out" 'plan=ready' "plan-safe ready token missing"
assert_contains "$out" 'branch-mode=safe' "plan-safe branch-mode missing"
assert_contains "$out" 'remove-worktree=yes' "plan-safe remove-worktree missing"
git -C "$repo" rev-parse --verify plan-safe-branch >/dev/null 2>&1 || fail "plan mode deleted the branch"
[ -d "$linked" ] || fail "plan mode removed the worktree"
pass "--plan reports ready (safe) and mutates nothing"

# --plan ready (force-squash)
repo="$(setup_repo plan-squash)"
commit_on_branch "$repo" plan-squash-branch "plan squash"
plan_squash_sha="$(git -C "$repo" rev-parse plan-squash-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --squash plan-squash-branch >/dev/null
git -C "$repo" commit -q -m "squash plan branch"
git -C "$repo" push -q origin main
linked="$TMP/plan-squash-linked"
git -C "$repo" worktree add -q "$linked" plan-squash-branch
out="$(run_helper "$repo" "$plan_squash_sha" --branch plan-squash-branch --worktree "$linked" --plan 2>&1)" || fail "plan-squash helper failed: $out"
assert_contains "$out" 'branch-mode=force-squash' "plan-squash branch-mode missing"
git -C "$repo" rev-parse --verify plan-squash-branch >/dev/null 2>&1 || fail "plan mode deleted the squash branch"
pass "--plan reports ready (force-squash) and mutates nothing"

# --plan blocked (dirty)
repo="$(setup_repo plan-dirty)"
commit_on_branch "$repo" plan-dirty-branch "plan dirty"
plan_dirty_sha="$(git -C "$repo" rev-parse plan-dirty-branch)"
printf 'dirt\n' > "$repo/untracked.txt"
out="$(run_helper "$repo" "$plan_dirty_sha" --branch plan-dirty-branch --worktree "$repo" --plan 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "plan-dirty exited $rc (want 1)"
assert_contains "$out" 'plan=blocked reason=dirty-worktree' "plan-dirty blocked token missing"
assert_not_contains "$out" 'cleanup=skipped' "plan mode emitted execute-mode skip token"
pass "--plan reports blocked (dirty) without mutating"

# --plan blocked (unproven local commits)
repo="$(setup_repo plan-unproven)"
commit_on_branch "$repo" plan-unproven-branch "provider"
plan_unproven_sha="$(git -C "$repo" rev-parse plan-unproven-branch)"
printf 'local-only\n' > "$repo/local-only.txt"
git -C "$repo" add local-only.txt
git -C "$repo" commit -q -m "local only"
git -C "$repo" checkout -q main
linked="$TMP/plan-unproven-linked"
git -C "$repo" worktree add -q "$linked" plan-unproven-branch
out="$(run_helper "$repo" "$plan_unproven_sha" --branch plan-unproven-branch --worktree "$linked" --plan 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "plan-unproven exited $rc (want 1)"
assert_contains "$out" 'plan=blocked reason=unproven-local-commits' "plan-unproven blocked token missing"
pass "--plan reports blocked (unproven) without mutating"

# --plan on the ACTIVE worktree (cwd == target, no --remove-active-worktree flag):
# read-only plan must reach plan=ready active=yes, not block on active-worktree-needs-flag.
repo="$(setup_repo plan-active)"
commit_on_branch "$repo" plan-active-branch "plan active"
plan_active_sha="$(git -C "$repo" rev-parse plan-active-branch)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff plan-active-branch -m "merge plan active"
git -C "$repo" push -q origin main
linked="$TMP/plan-active-linked"
git -C "$repo" worktree add -q "$linked" plan-active-branch
out="$(run_helper "$linked" "$plan_active_sha" --branch plan-active-branch --worktree "$linked" --plan 2>&1)" || fail "plan-active helper failed: $out"
assert_contains "$out" 'plan=ready' "plan-active ready token missing"
assert_contains "$out" 'active=yes' "plan-active should report active=yes"
assert_not_contains "$out" 'active-worktree-needs-flag' "read-only --plan must not block on the active flag"
[ -d "$linked" ] || fail "plan mode removed the active worktree"
pass "--plan on the active worktree reports ready (active=yes) without the flag"

# --- #741: control worktree selection ---

# CLI-16: primary worktree is the target while an UNRELATED linked worktree
# exists. The helper must keep the primary in place (control == target) and must
# never check the default branch out inside the unrelated linked worktree.
repo="$(setup_repo cli16-primary-target)"
# An unrelated, in-flight linked worktree on its own (unmerged) branch.
commit_on_branch "$repo" bystander "bystander work"
git -C "$repo" checkout -q main
bystander_wt="$TMP/cli16-bystander"
git -C "$repo" worktree add -q "$bystander_wt" bystander
# The branch we actually clean up: merged into main, primary left checked out on it.
commit_on_branch "$repo" primary-target "primary target"
primary_target_sha="$(git -C "$repo" rev-parse primary-target)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff primary-target -m "merge primary-target"
git -C "$repo" push -q origin main
git -C "$repo" checkout -q primary-target
# --plan: the primary tree is un-removable, so remove-worktree must be no.
out="$(run_helper "$repo" "$primary_target_sha" --branch primary-target --worktree "$repo" --plan 2>&1)" || fail "cli16 plan helper failed: $out"
assert_contains "$out" 'plan=ready' "cli16 plan ready token missing: $out"
assert_contains "$out" 'remove-worktree=no' "cli16 primary target must not be scheduled for removal: $out"
# --execute: in-place keep path, branch deleted, bystander worktree untouched.
out="$(run_helper "$repo" "$primary_target_sha" --branch primary-target --worktree "$repo" --remove-active-worktree 2>&1)" || fail "cli16 execute helper failed: $out"
assert_contains "$out" 'worktree=kept reason=main-worktree' "cli16 in-place keep token missing: $out"
git -C "$repo" rev-parse --verify primary-target >/dev/null 2>&1 && fail "cli16 merged branch still exists"
[ "$(git -C "$bystander_wt" symbolic-ref --quiet --short HEAD)" = "bystander" ] || fail "cli16 CLOBBERED the unrelated linked worktree (it is no longer on 'bystander')"
[ -d "$bystander_wt" ] || fail "cli16 removed the unrelated linked worktree"
pass "primary target with linked worktrees present keeps in place and never clobbers a bystander"

# CLI-17: target is a linked worktree but the control (primary) tree is on a
# non-default feature branch. The helper must refuse rather than check the
# default branch out over the primary's in-flight work.
repo="$(setup_repo cli17-nondefault-control)"
commit_on_branch "$repo" linked-target "linked target"
linked_target_sha="$(git -C "$repo" rev-parse linked-target)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff linked-target -m "merge linked-target"
git -C "$repo" push -q origin main
linked="$TMP/cli17-linked"
git -C "$repo" worktree add -q "$linked" linked-target
# Park the primary (the control) on a non-default, non-target feature branch.
git -C "$repo" checkout -q -b keep-here
# --plan: blocked with the new reason, no mutation.
out="$(run_helper "$repo" "$linked_target_sha" --branch linked-target --worktree "$linked" --plan 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "cli17 plan exited $rc (want 1): $out"
assert_contains "$out" 'plan=blocked reason=control-worktree-not-on-default' "cli17 plan blocked token missing: $out"
# --execute: skipped with the same reason; primary stays on keep-here, branch survives.
out="$(run_helper "$linked" "$linked_target_sha" --branch linked-target --worktree "$linked" --remove-active-worktree 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "cli17 execute exited $rc (want 1): $out"
assert_contains "$out" 'cleanup=skipped reason=control-worktree-not-on-default' "cli17 execute skip token missing: $out"
[ "$(git -C "$repo" symbolic-ref --quiet --short HEAD)" = "keep-here" ] || fail "cli17 CLOBBERED the primary control worktree (no longer on 'keep-here')"
git -C "$repo" rev-parse --verify linked-target >/dev/null 2>&1 || fail "cli17 deleted the target branch despite refusing"
pass "linked target with a non-default control worktree is refused, not clobbered"

# CLI-18: target is a linked worktree but the control (primary) tree is in
# DETACHED HEAD. A detached primary is in-flight work too (sitting on a specific
# commit), so the helper must refuse rather than check the default branch out
# over it — the empty-branch case must not slip past the guard.
repo="$(setup_repo cli18-detached-control)"
commit_on_branch "$repo" detach-target "detach target"
detach_target_sha="$(git -C "$repo" rev-parse detach-target)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff detach-target -m "merge detach-target"
git -C "$repo" push -q origin main
linked="$TMP/cli18-linked"
git -C "$repo" worktree add -q "$linked" detach-target
# Park the primary (the control) in detached HEAD with a clean tree.
git -C "$repo" checkout -q --detach
out="$(run_helper "$linked" "$detach_target_sha" --branch detach-target --worktree "$linked" --remove-active-worktree 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "cli18 detached control exited $rc (want 1): $out"
assert_contains "$out" 'cleanup=skipped reason=control-worktree-not-on-default' "cli18 detached control skip token missing: $out"
[ -z "$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] || fail "cli18 CLOBBERED the detached primary (it is now on a branch)"
git -C "$repo" rev-parse --verify detach-target >/dev/null 2>&1 || fail "cli18 deleted the target branch despite refusing"
pass "linked target with a detached-HEAD control worktree is refused, not clobbered"

# Unsupported backend emits the structured setup-error token (exit 2), not raw stderr.
# Keep the repo checked out on the target branch so the worktree gates pass and
# execution reaches the backend guard.
repo="$(setup_repo unsupported-backend)"
commit_on_branch "$repo" ub-branch "ub"
out="$( (cd "$repo"; PATH="$STUB_BIN:$PATH" ROADMAP_BACKEND=bogus bash "$HELPER" --branch ub-branch --worktree "$repo" 2>&1) )" && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "unsupported backend exited $rc (want 2): $out"
assert_contains "$out" 'cleanup=skipped reason=unsupported-backend' "unsupported-backend token missing"
pass "unsupported backend emits a structured token before requiring the backend"
