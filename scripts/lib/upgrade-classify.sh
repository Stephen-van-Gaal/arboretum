#!/usr/bin/env bash
# owner: project-upgrade
# scope: plugin-only
# Pure classification for upgrade-sync. Sourceable; no side effects.

# classify_file BASE OURS THEIRS IN_PLUGIN(yes|no) IN_TREE(yes|no) -> action
# Actions: add overwrite-safe overwrite-local keep-local conflict converged
#          unchanged report-removed
#
# Plugin-wins policy (#394): for a managed framework file present in BOTH the tree
# and the plugin, the plugin copy always wins. A local edit is never preserved
# (no silent keep-local) and never surfaced as an edit conflict — it classifies as
# overwrite-local: applied like overwrite-safe, but named distinctly so the plan can
# flag that it discards local edits (git is the recovery net). Adopters do not fork
# framework code; only project-specific documentation stays local.
#
# Presence-mismatch (deletion) rules remain base-aware — plugin-wins governs edits,
# not deletions:
#   (a) untracked user-owned files (base empty) absent from plugin are NOT ours to
#       manage → unchanged (never falsely report-removed).
#   (b) a tracked file (base non-empty) the user intentionally deleted is respected
#       (keep-local), not silently re-added.
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
  if [ "$ours" = "$theirs" ]; then
    # Identical content — nothing to copy. unchanged if it also matches base,
    # otherwise converged (both arrived at the same content; record the new base).
    if [ "$ours" = "$base" ]; then echo unchanged; else echo converged; fi
    return
  fi
  # ours != theirs — plugin always wins for managed framework files:
  if [ "$ours" = "$base" ]; then
    # Local untouched since baseline; clean framework update.
    echo overwrite-safe
  else
    # Local diverged from baseline (edited or untracked-divergent); plugin-wins
    # replaces it. Distinct action so the plan can surface the discarded local edit.
    echo overwrite-local
  fi
}
