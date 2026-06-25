#!/usr/bin/env bash
# owner: session-heartbeat
# scope: plugin-only
# heartbeat.sh — per-machine liveness sentinel (sourced, never executed).
# Writes/refreshes a branch-keyed sentinel from the refresh hooks and answers
# "is branch B's session live within the TTL?" for the collision read-back (#715).
# See docs/superpowers/specs/2026-06-11-heartbeat-sentinel-design.md.
#
# Resolution is deliberately cheap (a few `git` plumbing calls): heartbeat_touch
# runs on every Bash tool call via the pre-commit hook, so it must NOT pull in the
# full workspace-context resolver (remote/base-ref probing). It echoes no
# author-controlled content, so it needs no scrub primitive.
[ -n "${BASH_VERSION:-}" ] || { echo "heartbeat.sh requires bash" >&2; return 1 2>/dev/null || exit 1; }

ARBO_HEARTBEAT_TTL_SECONDS="${ARBO_HEARTBEAT_TTL_SECONDS:-14400}"             # 4h
ARBO_HEARTBEAT_HARD_CAP_SECONDS="${ARBO_HEARTBEAT_HARD_CAP_SECONDS:-604800}"  # 7d
ARBO_HEARTBEAT_DEBOUNCE_SECONDS="${ARBO_HEARTBEAT_DEBOUNCE_SECONDS:-60}"      # skip rewrite if fresher

# Map a branch name to its issue number via the leading-digit convention
# (feat/715-foo -> 715), mirroring workspace-collision-check.sh.
_heartbeat_branch_issue() {
  local slug="${1#*/}"; slug="${slug%-build}"
  printf '%s' "$slug" | grep -oE '^[0-9]+' || true
}

# Branch short-name -> sentinel filename slug.
_heartbeat_slug() { printf '%s' "$1" | tr '/' '-'; }

# Resolve the SHARED heartbeat dir, creating it. Echoes the path.
# Sentinels must live in ONE place all worktrees see — the checker and the live
# session are usually in DIFFERENT worktrees — so we anchor on the main-tree root
# (dirname of the shared git-common-dir), not the per-worktree top-level.
_heartbeat_dir() {
  local cdir root
  cdir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cdir" in /*) ;; *) cdir="$(cd "$cdir" 2>/dev/null && pwd)" || return 1 ;; esac
  root="$(dirname "$cdir")"
  local d="$root/.arboretum/heartbeat"
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$d"
}

# File mtime as an epoch (0 on failure). BSD/macOS `stat -f` first, GNU `stat -c`
# as fallback — cheap (one stat, no python) for the per-Bash-call debounce.
_heartbeat_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Read the integer last_seen epoch from a sentinel file (0 on any failure).
_heartbeat_last_seen() {
  python3 -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1]))["last_seen"]))
except Exception:
    print(0)' "$1" 2>/dev/null || echo 0
}

# Echo "<stored-branch>\t<last_seen-epoch>" from a sentinel (one python spawn;
# "\t0" on failure). The stored branch lets callers reject a slug collision —
# two branches differing only by '/' vs '-' map to the same filename, so the
# stored field is the authority for which branch the sentinel actually belongs to.
_heartbeat_read() {
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("%s\t%d" % (d.get("branch",""), int(d.get("last_seen",0))))
except Exception:
    print("\t0")' "$1" 2>/dev/null || printf '\t0'
}

# Remove sentinels older than the hard cap (cruft control).
_heartbeat_prune() {
  local dir="$1" now cap f last
  now="$(date +%s)"; cap="$ARBO_HEARTBEAT_HARD_CAP_SECONDS"
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    last="$(_heartbeat_last_seen "$f")"
    [ "$((now - last))" -gt "$cap" ] && rm -f "$f"
  done
}

# Refresh the sentinel for the current branch. No-op off-issue (e.g. main) or
# on detached HEAD. Debounced: a write within the last DEBOUNCE seconds is a
# no-op, so the per-Bash-call hot path stays cheap during autonomous /build runs.
heartbeat_touch() {
  local branch; branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 0
  [ -n "$branch" ] || return 0
  [ -n "$(_heartbeat_branch_issue "$branch")" ] || return 0
  local dir; dir="$(_heartbeat_dir)" || return 0
  local out; out="$dir/$(_heartbeat_slug "$branch").json"
  local now; now="$(date +%s)"
  if [ -f "$out" ]; then
    local mt; mt="$(_heartbeat_mtime "$out")"
    [ "$((now - mt))" -lt "$ARBO_HEARTBEAT_DEBOUNCE_SECONDS" ] && return 0
  fi
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
  ARBO_HB_BRANCH="$branch" \
  ARBO_HB_PATH="$root" \
  ARBO_HB_NOW="$now" \
  ARBO_HB_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ARBO_HB_OUT="$out" \
  python3 -c '
import json, os
out = os.environ["ARBO_HB_OUT"]
# Per-writer temp (PID-scoped) so two concurrent refreshers of the same branch
# never rename a half-written shared inode into place. os.replace is atomic, so a
# concurrent reader always sees a complete old or new file.
tmp = "%s.%d.tmp" % (out, os.getpid())
with open(tmp, "w") as f:
    json.dump({
        "branch": os.environ["ARBO_HB_BRANCH"],
        "worktree_path": os.environ["ARBO_HB_PATH"],
        "last_seen": int(os.environ["ARBO_HB_NOW"]),
        "last_seen_iso": os.environ["ARBO_HB_ISO"],
    }, f)
os.replace(tmp, out)
' 2>/dev/null || true
  _heartbeat_prune "$dir"
}

# Is branch B's session live (its sentinel is within TTL)? Return 0 if live, 1
# if not (stale or no sentinel). Queries the SPECIFIC branch — never "any branch
# for the issue" — so the caller's own live session can't mask a dead sibling.
heartbeat_branch_is_live() {
  local branch="$1"
  [ -n "$branch" ] || return 1
  local dir; dir="$(_heartbeat_dir)" || return 1
  local f; f="$dir/$(_heartbeat_slug "$branch").json"
  [ -f "$f" ] || return 1
  local rec stored last
  rec="$(_heartbeat_read "$f")"
  stored="${rec%%$'\t'*}"; last="${rec##*$'\t'}"
  [ "$stored" = "$branch" ] || return 1   # slug collision: sentinel belongs to another branch
  local now; now="$(date +%s)"
  [ "$((now - last))" -le "$ARBO_HEARTBEAT_TTL_SECONDS" ]
}

# Echo whole hours since the branch's sentinel was last seen, or nothing.
heartbeat_age_hours_for_branch() {
  local branch="$1"
  local dir; dir="$(_heartbeat_dir)" || { echo ""; return 0; }
  local f; f="$dir/$(_heartbeat_slug "$branch").json"
  [ -f "$f" ] || { echo ""; return 0; }
  local rec stored last
  rec="$(_heartbeat_read "$f")"
  stored="${rec%%$'\t'*}"; last="${rec##*$'\t'}"
  [ "$stored" = "$branch" ] || { echo ""; return 0; }   # slug collision: not this branch's sentinel
  [ "$last" -gt 0 ] || { echo ""; return 0; }
  local now; now="$(date +%s)"
  printf '%s' "$(( (now - last) / 3600 ))"
}
