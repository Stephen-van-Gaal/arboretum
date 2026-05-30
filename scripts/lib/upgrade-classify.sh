#!/usr/bin/env bash
# owner: project-upgrade
# Pure classification for upgrade-sync. Sourceable; no side effects.

# classify_file BASE OURS THEIRS IN_PLUGIN(yes|no) IN_TREE(yes|no) -> action
# Actions: add overwrite-safe keep-local conflict converged unchanged report-removed
#
# Presence-mismatch rules are base-aware to avoid two bugs:
#   (a) untracked user-owned files (base empty) absent from plugin were falsely
#       flagged report-removed — they are not ours to manage.
#   (b) a tracked file (base non-empty) the user intentionally deleted locally
#       was unconditionally re-added by --apply, clobbering the deletion.
classify_file() {
  local base="$1" ours="$2" theirs="$3" in_plugin="$4" in_tree="$5"
  if [ "$in_plugin" = no ] && [ "$in_tree" = yes ]; then
    # Only report-removed when we previously tracked this file (base non-empty).
    # A user-owned file we never shipped should be left alone (unchanged).
    if [ -n "$base" ]; then echo report-removed; else echo unchanged; fi
    return
  fi
  if [ "$in_plugin" = yes ] && [ "$in_tree" = no ]; then
    if [ -z "$base" ]; then
      # Genuinely new from plugin — never seen before.
      echo add
    elif [ "$theirs" = "$base" ]; then
      # Tracked file the user intentionally deleted; plugin unchanged → respect deletion.
      echo keep-local
    else
      # Plugin changed a file the user deleted — flag for manual resolution.
      echo conflict
    fi
    return
  fi
  # present in both tree and plugin:
  if [ "$ours" = "$base" ]; then
    if [ "$theirs" = "$base" ]; then echo unchanged; else echo overwrite-safe; fi
    return
  fi
  # ours != base (locally edited or untracked-divergent):
  if [ "$theirs" = "$base" ]; then echo keep-local; return; fi
  if [ "$ours" = "$theirs" ];  then echo converged; else echo conflict; fi
}
