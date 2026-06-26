#!/usr/bin/env bash
# owner: workspace-context
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-contract-workspace-context.sh - Contract test for
# docs/contracts/workspace-context.contract.md (seam: workspace-context).
# shellcheck disable=SC1090  # $HELPER is resolved at runtime; sourcing it dynamically is intentional.
set -uo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/workspace-context.sh"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER not found" >&2; exit 1; }

# Canonicalize the temp dir (pwd -P) so it matches git's physical-path output.
# macOS symlinks /var -> /private/var; git rev-parse --show-toplevel returns the
# resolved path, so a bare mktemp -d value would never compare equal (#623).
FIX=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# Build a bare "remote" + a clone with a real default branch, all offline.
git init -q --bare "$FIX/remote.git"
git clone -q "$FIX/remote.git" "$FIX/work" 2>/dev/null
cd "$FIX/work" || exit 1
git config user.email t@t; git config user.name t
git symbolic-ref HEAD refs/heads/main
echo seed > f; git add f; git commit -qm seed
git push -q origin main 2>/dev/null
git remote set-head origin main 2>/dev/null

# ---- WSC-1: tree-root resolves to THIS worktree, not the main checkout ----
git worktree add -q "$FIX/wt" -b feat/x 2>/dev/null
( cd "$FIX/wt" || exit 1
  . "$HELPER"
  root="$(workspace_tree_root)"
  [ "$root" = "$FIX/wt" ] && echo PASS-WSC1 || echo "FAIL-WSC1 got=$root"
) | grep -q PASS-WSC1 && pass "WSC-1 tree-root is the linked worktree" || fail_case "WSC-1 tree-root wrong"

# ---- WSC-2: current branch ----
. "$HELPER"
b="$(workspace_branch)"
[ "$b" = "main" ] && pass "WSC-2 branch=main" || fail_case "WSC-2 branch wrong" "got=$b"

# ---- WSC-3: cache path is <tree-root>/.arboretum/workspace-cache.json ----
cp="$(workspace_cache_path)"
[ "$cp" = "$FIX/work/.arboretum/workspace-cache.json" ] && pass "WSC-3 cache path" || fail_case "WSC-3 cache path wrong" "got=$cp"

# Getters echo exactly one value and are subshell-safe; the source classification
# (ARBO_BASE_SOURCE) is a workspace_context output, asserted in the Task 3 block.

# ---- WSC-4: base ref = origin/main (remote-tracking) when origin/HEAD is set ----
. "$HELPER"
base="$(workspace_base_ref)"
[ "$base" = "origin/main" ] && pass "WSC-4 base=origin/main (origin/HEAD set)" || fail_case "WSC-4 base wrong" "got=$base"

# ---- WSC-5: origin/HEAD unset -> falls through to the origin/main tracking ref ----
git symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
base5="$(workspace_base_ref)"
[ "$base5" = "origin/main" ] && pass "WSC-5 fallthrough base=origin/main" || fail_case "WSC-5 base wrong" "got=$base5"

# ---- WSC-6: no remote-tracking base -> local ref echoed + stderr #381 warning ----
( git init -q "$FIX/noremote"; cd "$FIX/noremote" || exit 1
  git config user.email t@t; git config user.name t
  echo x > a; git add a; git commit -qm x
  . "$HELPER"
  ref="$(workspace_base_ref 2>/dev/null)"           # local ref (no remote)
  warn="$(workspace_base_ref 2>&1 >/dev/null)"      # #381 stderr warning
  { [ "$ref" = "main" ] && printf '%s' "$warn" | grep -qi '381'; } \
    && echo PASS-WSC6 || echo "FAIL-WSC6 ref=$ref warn=$warn"
) | grep -q PASS-WSC6 && pass "WSC-6 local ref + #381 warning" || fail_case "WSC-6 fallback/warning missing"

# ---- source classification: ARBO_BASE_SOURCE is set by the master resolver ----
cd "$FIX/work" || exit 1
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null  # restore origin/HEAD
. "$HELPER"; workspace_context
[ "$ARBO_BASE_SOURCE" = "remote-head" ] && pass "source=remote-head" || fail_case "source remote-head wrong" "got=${ARBO_BASE_SOURCE:-}"
git symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
workspace_context
[ "$ARBO_BASE_SOURCE" = "remote-main" ] && pass "source=remote-main" || fail_case "source remote-main wrong" "got=${ARBO_BASE_SOURCE:-}"
( cd "$FIX/noremote" || exit 1; . "$HELPER"; workspace_context >/dev/null 2>&1
  [ "$ARBO_BASE_SOURCE" = "local-fallback" ] && echo PASS-SRC-LF || echo "FAIL-SRC-LF got=${ARBO_BASE_SOURCE:-}"
) | grep -q PASS-SRC-LF && pass "source=local-fallback" || fail_case "source local-fallback wrong"

# ---- WSC-7: --fetch against a local bare remote advances the tracking ref ----
( cd "$FIX/work" || exit 1
  echo more >> f; git commit -qam more; git push -q origin main 2>/dev/null
  cd "$FIX/wt" || exit 1; git fetch -q origin 2>/dev/null
  # Rewind the tracking ref so --fetch has something to advance.
  git update-ref refs/remotes/origin/main "refs/remotes/origin/main^" 2>/dev/null
  before="$(git rev-parse refs/remotes/origin/main)"
  . "$HELPER"; workspace_base_ref --fetch >/dev/null 2>&1
  after="$(git rev-parse refs/remotes/origin/main)"
  [ "$before" != "$after" ] && echo PASS-WSC7 || echo "FAIL-WSC7 before=$before after=$after"
) | grep -q PASS-WSC7 && pass "WSC-7 --fetch advances tracking ref" || fail_case "WSC-7 --fetch no-op"

# ---- WSC-8: master resolver sets all ARBO_* ; detached HEAD -> empty branch ----
cd "$FIX/work" || exit 1; . "$HELPER"; workspace_context
{ [ -n "$ARBO_TREE_ROOT" ] && [ -n "$ARBO_BASE_REF" ] && [ -n "$ARBO_REMOTE" ] \
  && [ "$ARBO_WORKSPACE_CACHE" = "$ARBO_TREE_ROOT/.arboretum/workspace-cache.json" ]; } \
  && pass "WSC-8 master resolver sets ARBO_*" || fail_case "WSC-8 ARBO_* incomplete" "$(set | grep ^ARBO_)"

git checkout -q --detach HEAD
. "$HELPER"; workspace_context
[ -z "$ARBO_BRANCH" ] && [ -n "$ARBO_BASE_REF" ] && pass "WSC-8 detached HEAD -> empty branch, base still resolves" || fail_case "WSC-8 detached handling wrong" "branch=$ARBO_BRANCH base=$ARBO_BASE_REF"
git checkout -q main

# ---- scrub: a crafted control-char branch name is stripped on output ----
git checkout -q -b "$(printf 'feat/x\x07y')" 2>/dev/null
. "$HELPER"; nb="$(workspace_branch)"
case "$nb" in *$'\x07'*) fail_case "scrub: control char survived" "got=$nb";; *) pass "scrub strips control chars from branch";; esac
git checkout -q main

# ---- not-a-git-repo: workspace_context returns non-zero, vars empty ----
( cd "$FIX" || exit 1; . "$HELPER"
  if workspace_context 2>/dev/null; then echo "FAIL-NOREPO returned 0"
  else [ -z "${ARBO_TREE_ROOT:-}" ] && echo PASS-NOREPO || echo "FAIL-NOREPO vars set"; fi
) | grep -q PASS-NOREPO && pass "not-a-git-repo -> non-zero, empty vars" || fail_case "not-a-git-repo handling wrong"

# ---- WSC-9: helper sources cleanly under zsh (consumers run in the user's shell) ----
# SKILL.md bash blocks are executed by the agent's shell (zsh here), where
# ${BASH_SOURCE[0]} is empty. Sourcing must still resolve the scrub lib and the
# base ref. Guarded on zsh being installed so the suite stays green on bash-only CI.
if command -v zsh >/dev/null 2>&1; then
  zres="$(WSC_HELPER="$HELPER" WSC_DIR="$FIX/work" zsh -c '
    cd "$WSC_DIR" || exit 1
    source "$WSC_HELPER" 2>/dev/null
    type scrub_control_chars >/dev/null 2>&1 || { printf MISSING-SCRUB; exit 0; }
    printf "%s" "$(workspace_base_ref 2>/dev/null)"
  ')"
  [ "$zres" = "origin/main" ] && pass "WSC-9 zsh: helper sources + scrub loads + base resolves" \
    || fail_case "WSC-9 zsh sourcing broken" "got=$zres"
else
  echo "SKIP: WSC-9 — zsh not installed"
fi

# ---- WSC-10: author-controlled REMOTE name is control-char-scrubbed (security) ----
# git permits the 0x9b C1 CSI byte in remote names; workspace_remote / ARBO_REMOTE
# feed into Claude's context, so they must be scrubbed like branch/default/tree-root.
( git init -q "$FIX/evilremote"; cd "$FIX/evilremote" || exit 1
  git config user.email t@t; git config user.name t
  git remote add "$(printf 'up\x9bX')" https://example.invalid/r.git 2>/dev/null
  . "$HELPER"
  r="$(workspace_remote)"
  [ "$r" = "upX" ] && echo PASS-WSC10 || echo "FAIL-WSC10 got=[$r]"
) | grep -q PASS-WSC10 && pass "WSC-10 remote name scrubbed" || fail_case "WSC-10 remote name not scrubbed"

# ---- WSC-11: scrub-load failure fails CLOSED (no silent unscrubbed/empty pass-through) ----
# If the scrub primitive can't be sourced, sourcing the helper must return non-zero
# rather than defining getters that emit unscrubbed (or silently empty) values.
mkdir -p "$FIX/nolib"
cp "$HELPER" "$FIX/nolib/workspace-context.sh"   # copied WITHOUT a sibling lib/scrub-control-chars.sh
if ( . "$FIX/nolib/workspace-context.sh" ) >/dev/null 2>&1; then
  fail_case "WSC-11 sourcing should fail closed when scrub lib is missing"
else
  pass "WSC-11 fail-closed when scrub primitive cannot load"
fi

# ---- WSC-12: stale origin/HEAD (target ref gone) falls through to origin/main ----
( cd "$FIX/work" || exit 1
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/nonexistent 2>/dev/null
  . "$HELPER"
  ref="$(workspace_base_ref 2>/dev/null)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null  # restore
  [ "$ref" = "origin/main" ] && echo PASS-WSC12 || echo "FAIL-WSC12 ref=$ref"
) | grep -q PASS-WSC12 && pass "WSC-12 stale origin/HEAD falls through to origin/main" || fail_case "WSC-12 stale HEAD not handled"

# ---- WSC-13: --fetch recovers a remote base when the tracking ref was missing ----
( git clone -q "$FIX/remote.git" "$FIX/recover" 2>/dev/null; cd "$FIX/recover" || exit 1
  git config user.email t@t; git config user.name t
  git update-ref -d refs/remotes/origin/main 2>/dev/null
  git symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
  . "$HELPER"
  before="$(workspace_base_ref 2>/dev/null)"          # local-fallback -> "main"
  after="$(workspace_base_ref --fetch 2>/dev/null)"   # fetch recreates origin/main -> "origin/main"
  { [ "$before" = "main" ] && [ "$after" = "origin/main" ]; } \
    && echo PASS-WSC13 || echo "FAIL-WSC13 before=$before after=$after"
) | grep -q PASS-WSC13 && pass "WSC-13 --fetch recovers remote base from local-fallback" || fail_case "WSC-13 --fetch recovery broken"

# ---- WSC-14: is_session_worktree — 1 in primary tree, 0 in a linked worktree, 2 outside git ----
# Authoritative via git's own registration (--git-dir under .git/worktrees/<n> for a
# linked tree vs the shared --git-common-dir). $FIX/work is the primary clone; $FIX/wt
# is the linked worktree added in WSC-1; $FIX itself is not a work tree.
rc_primary=0; ( cd "$FIX/work" && . "$HELPER" && workspace_is_session_worktree ); rc_primary=$?
rc_linked=0;  ( cd "$FIX/wt"   && . "$HELPER" && workspace_is_session_worktree ); rc_linked=$?
rc_outside=0; ( cd "$FIX"      && . "$HELPER" && workspace_is_session_worktree ); rc_outside=$?
rc_bare=0; ( cd "$FIX/remote.git" && . "$HELPER" && workspace_is_session_worktree ) || rc_bare=$?
{ [ "$rc_primary" = 1 ] && [ "$rc_linked" = 0 ] && [ "$rc_outside" = 2 ] && [ "$rc_bare" = 2 ]; } \
  && pass "WSC-14 is_session_worktree (primary=1, linked=0, outside=2, bare=2)" \
  || fail_case "WSC-14 is_session_worktree wrong" "primary=$rc_primary linked=$rc_linked outside=$rc_outside bare=$rc_bare"

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
