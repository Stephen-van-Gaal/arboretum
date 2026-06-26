#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# Unit smoke for .claude/hooks/worktree-write-guard.sh — PreToolUse guard that
# BLOCKS (permissionDecision: deny) a Write/Edit/NotebookEdit aimed at the
# MAIN-tree path from a linked worktree session, naming the corrected path
# (#825, #826). Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/.claude/hooks/worktree-write-guard.sh"
[ -f "$SUT" ] || { echo "FAIL: $SUT not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
GIT_ID=(-c user.email=t@t -c user.name=t)
fail=0
pass() { echo "PASS: $1"; }
fk()   { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  detail: $2" >&2; fail=1; }

# JSON helper: a PreToolUse payload for <tool>, placing <path> under <field>
# (file_path for Write/Edit, notebook_path for NotebookEdit).
payload() { # <tool_name> <path_field> <path>
  ARBO_T="$1" ARBO_K="$2" ARBO_F="$3" python3 -c '
import json,os
print(json.dumps({"tool_name":os.environ["ARBO_T"],
                  "tool_input":{os.environ["ARBO_K"]:os.environ["ARBO_F"]}}))'
}
# Pull the deny decision / reason out of the hook's stdout JSON (empty if absent).
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# Build an offline repo with a real linked worktree.
FIX=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$FIX"' EXIT
MAIN="$FIX/main"
git init -q "$MAIN"
cd "$MAIN" || exit 1
git "${GIT_ID[@]}" symbolic-ref HEAD refs/heads/main
echo seed > f; git "${GIT_ID[@]}" add f; git "${GIT_ID[@]}" commit -qm seed
WT="$FIX/wt-feature"
git "${GIT_ID[@]}" worktree add -q "$WT" -b feat/x 2>/dev/null

# --- WG-main-from-wt: worktree session, Write under MAIN tree -> deny, exit 0 ---
target="$MAIN/docs/specs/foo.spec.md"
out=$( cd "$WT" && payload Write file_path "$target" | bash "$SUT" 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(decision "$out")" = "deny" ]; } \
  && pass "WG-main-from-wt: main-tree Write from worktree -> deny, exit 0" \
  || fk "WG-main-from-wt" "rc=$rc out=$out"
# The deny reason must name the corrected worktree-rooted path.
reason "$out" | grep -qF "$WT/docs/specs/foo.spec.md" \
  && pass "WG-main-from-wt2: deny reason names the corrected worktree-rooted path" \
  || fk "WG-main-from-wt2" "reason=$(reason "$out")"

# --- WG-notebook: NotebookEdit uses notebook_path (not file_path) -> still
#     denied with the corrected path (#826 P2) ---
out=$( cd "$WT" && payload NotebookEdit notebook_path "$MAIN/analysis/nb.ipynb" | bash "$SUT" 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(decision "$out")" = "deny" ] && reason "$out" | grep -qF "$WT/analysis/nb.ipynb"; } \
  && pass "WG-notebook: NotebookEdit notebook_path main-tree target -> deny w/ corrected path" \
  || fk "WG-notebook" "rc=$rc out=$out"

# --- WG-wt-rooted: worktree session, file UNDER the worktree -> silent allow ---
out=$( cd "$WT" && payload Edit file_path "$WT/docs/specs/foo.spec.md" | bash "$SUT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && pass "WG-wt-rooted: worktree-rooted target -> silent, exit 0" \
  || fk "WG-wt-rooted" "rc=$rc out=$out"

# --- WG-primary: primary-tree session -> silent no-op ---
out=$( cd "$MAIN" && payload Write file_path "$MAIN/x.md" | bash "$SUT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && pass "WG-primary: primary-tree session -> silent no-op" \
  || fk "WG-primary" "rc=$rc out=$out"

# --- WG-nongit: non-git directory -> silent no-op ---
NONGIT="$FIX/plain"; mkdir -p "$NONGIT"
out=$( cd "$NONGIT" && payload Write file_path "$NONGIT/x.md" | bash "$SUT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && pass "WG-nongit: non-git dir -> silent no-op" \
  || fk "WG-nongit" "rc=$rc out=$out"

# --- WG-relpath: relative path from a worktree session climbing into the main
#     tree -> resolved + denied (path-resolution coverage) ---
out=$( cd "$WT" && payload Write file_path "../main/docs/specs/bar.spec.md" | bash "$SUT" 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(decision "$out")" = "deny" ]; } \
  && pass "WG-relpath: relative main-tree path resolved + denied" \
  || fk "WG-relpath" "rc=$rc out=$out"

# --- WG-symlink: a worktree path that is a SYMLINK pointing into the main tree
#     is classified by its real target -> deny (#826 P3) ---
ln -s "$MAIN/real.md" "$WT/link.md"
out=$( cd "$WT" && payload Write file_path "$WT/link.md" | bash "$SUT" 2>/dev/null ); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(decision "$out")" = "deny" ]; } \
  && pass "WG-symlink: worktree symlink pointing into main tree -> deny" \
  || fk "WG-symlink" "rc=$rc out=$out"

# --- WG-noinput: missing path -> silent no-op ---
out=$( cd "$WT" && printf '{"tool_name":"Write","tool_input":{}}' | bash "$SUT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && pass "WG-noinput: missing path -> silent no-op" \
  || fk "WG-noinput" "rc=$rc out=$out"

# --- WG-malformed: non-JSON input -> silent no-op ---
out=$( cd "$WT" && printf 'not json at all' | bash "$SUT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
  && pass "WG-malformed: non-JSON -> silent no-op" \
  || fk "WG-malformed" "rc=$rc out=$out"

# --- WG-scrub: a control char in the path text is stripped from the deny reason
#     (defense-in-depth, CLAUDE.md § scrub) ---
ctrl=$(printf 'foo\033bar')
out=$( cd "$WT" && payload Write file_path "$MAIN/docs/$ctrl.md" | bash "$SUT" 2>/dev/null ); rc=$?
if [ "$rc" -eq 0 ] && [ "$(decision "$out")" = "deny" ]; then
  if reason "$out" | LC_ALL=C grep -q $'\033'; then
    fk "WG-scrub" "raw ESC leaked into deny reason"
  else
    pass "WG-scrub: control char stripped from deny reason"
  fi
else
  fk "WG-scrub" "rc=$rc out=$out"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
