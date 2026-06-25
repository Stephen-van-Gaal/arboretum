#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# state-dir.sh — single source of truth for the arboretum state directory.
#
# Sourceable, side-effect-free. Defines arboretum_state_dir(), which echoes the
# base directory under which generated token/state artifacts live. The whole
# point is device-stability across git worktrees: a linked worktree has its own
# working dir and its own `git rev-parse --show-toplevel`, so a cwd-relative
# `.arboretum` fragments state across every worktree and loses it on
# `git worktree remove`. Only `--git-common-dir` resolves to the shared main
# checkout, so that is what we anchor to.
#
# Resolution precedence (#673, design decision D25):
#   1. $ARBORETUM_STATE_DIR — explicit operator override, echoed verbatim.
#   2. Inside a git repo    — <main-checkout>/.arboretum (via --git-common-dir).
#   3. Otherwise            — ".arboretum" (cwd-relative; preserves the prior
#                             standalone/non-repo behaviour).
#
# Consumers append their subtree, e.g. "$(arboretum_state_dir)/token-journey".

arboretum_state_dir() {
  if [ -n "${ARBORETUM_STATE_DIR:-}" ]; then
    printf '%s\n' "$ARBORETUM_STATE_DIR"
    return 0
  fi

  # The main working tree is the FIRST entry of `git worktree list` (git lists
  # the main tree first, then linked worktrees). This is robust where the parent
  # of `--git-common-dir` is NOT the checkout — submodules and `--separate-git-dir`
  # put the common dir under `.git/modules/...` or an external path, which would
  # otherwise send artifacts into git metadata. Canonicalize to a physical path
  # (pwd -P) so the result is identical from the main tree, a linked worktree, or
  # a nested subdir, and stable across symlinked prefixes (macOS /var -> /private/var).
  local main_wt main_root
  main_wt="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
  if [ -n "$main_wt" ]; then
    main_root="$(cd "$main_wt" 2>/dev/null && pwd -P)" || main_root=""
    if [ -n "$main_root" ]; then
      printf '%s/.arboretum\n' "$main_root"
      return 0
    fi
  fi

  printf '%s\n' ".arboretum"
}
