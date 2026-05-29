#!/usr/bin/env bash
# owner: git-workflow-tooling
# PreToolUse hook for Bash: block git commit on protected branches.
#
# Intercepts Bash tool calls containing "git commit" and checks
# the current branch against a protected list (main, master).
# Blocking: exits 2 on protected branch.
#
# Limitation: pattern match on command string is best-effort.
# The CLAUDE.md instruction is the primary control; this hook
# is defense-in-depth, not a security boundary.

set -euo pipefail

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Layer 2+ only — skip for Layer 0-1 projects
# `|| echo ''` guards against sed's file-open failure when
# .arboretum.yml is absent — `set -euo pipefail` would otherwise
# abort the script before the ${LAYER:-0} fallback runs. Round-4
# review caught this — CLI-2's "missing config → silent exit 0"
# promise was previously not satisfied for fresh/non-Arboretum repos.
LAYER=$(sed -n 's/^layer:[[:space:]]*\([0-9]\).*/\1/p' "$PROJECT_DIR/.arboretum.yml" 2>/dev/null || echo '')
LAYER="${LAYER:-0}"
[ "$LAYER" -lt 2 ] && exit 0

# Only fire on commands invoking `git commit`. Accepts an optional
# `-C <dir>` operand between `git` and `commit` so cross-repo shapes
# (`git -C /tmp/foo commit -m x`) still trigger the gate. The
# trailing `(\s|$)` boundary keeps `git commit-tree`-style subcommands
# from matching. Expanded in PR 5 per D1 (#139 closure path).
#
# The jq stdin read is guarded with `2>/dev/null || echo ''` so
# malformed-JSON input (developer-driven, corrupted payload) no-ops
# at exit 0 rather than aborting via set -euo pipefail with jq's
# parse-error code (5).
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo '')
# Boundary `([^a-zA-Z0-9_-]|$)` accepts space, end-of-string, and shell
# delimiters (`;`, `|`, `)`, `&`, `<`, `>`) after `commit` — `git commit;
# echo done` and similar shapes are still real commit invocations.
# Excludes word-continuation chars (`a-zA-Z0-9_-`) so `git commit-tree`
# and `git commit_log` style subcommands do not match. Widened in
# round 1 of /land review per PR #372 (Copilot finding).
if ! echo "$COMMAND" | grep -qE 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit([^a-zA-Z0-9_-]|$)'; then
  exit 0
fi

# ── Resolve commit target dir from the wrapped command ──────────────
# Priority: explicit `git -C <dir>` > leading `cd <dir> &&` > $PWD.
# Best-effort, defense-in-depth — see #139 for full rationale.
#
# `|| true` guards each grep pipeline against `set -euo pipefail`:
# when no match is present, `grep -oE` exits 1, `pipefail` propagates
# that to the pipeline, and the unprotected assignment would abort
# the script before the next-priority fallback can run.

# Extract the chunk containing `git ... commit`, bounded by &&/;/|/().
# Without this scoping, a preceding non-commit `git -C` would extract
# the wrong target (round-4 fix).
COMMIT_CHUNK=$( { printf '%s' "$COMMAND" \
  | grep -oE '[^&;|()]*git[[:space:]][^&;|()]*commit[^&;|()]*' \
  | head -1 ; } || true )

GIT_C_TARGET=$( { printf '%s' "$COMMIT_CHUNK" \
  | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' \
  | head -1 \
  | awk '{print $NF}' ; } || true )

CD_TARGET=$( { printf '%s' "$COMMAND" \
  | grep -oE '^[[:space:]]*cd[[:space:]]+[^[:space:]]+[[:space:]]*&&' \
  | head -1 \
  | awk '{print $2}' ; } || true )

# Strip a single leading/trailing single-or-double quote left over from
# `git -C '/repo'` / `cd "/repo" &&` shapes — awk preserves the quote
# characters as part of the non-whitespace token, and passing them to
# `git -C` verbatim makes git fail (literal-named dir not found) and
# the protected-branch check silently permits. Round 1 /land fix.
GIT_C_TARGET="${GIT_C_TARGET#[\'\"]}"
GIT_C_TARGET="${GIT_C_TARGET%[\'\"]}"
CD_TARGET="${CD_TARGET#[\'\"]}"
CD_TARGET="${CD_TARGET%[\'\"]}"

# Anchor a relative `git -C <relpath>` against its chunk's `cd` base
# (if present) else $PWD. Without this, `cd /base && git -C repo
# commit` resolves to `<host-pwd>/repo` instead of `/base/repo`,
# bypassing the protected-branch check when the host project is on
# a feature branch and `/base/repo` is on `main`. Round 1 /land fix.
if [ -n "$GIT_C_TARGET" ] && [ "${GIT_C_TARGET#/}" = "$GIT_C_TARGET" ]; then
  GIT_C_TARGET="${CD_TARGET:-$PWD}/$GIT_C_TARGET"
fi

COMMIT_CWD="${GIT_C_TARGET:-${CD_TARGET:-$PWD}}"

# ── Read the resolved target's branch ──────────────────────────────
# git -C returns nonzero (and emits to stderr) when the target is not
# a git repo. Suppress stderr and set BRANCH=unknown — the loop below
# treats unknown as "no protection to apply" and exits 0.

BRANCH=$(git -C "$COMMIT_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Protected branches — edit this list to customize
PROTECTED_BRANCHES=("main" "master")

for protected in "${PROTECTED_BRANCHES[@]}"; do
  if [ "$BRANCH" = "$protected" ]; then
    echo "[Branch Protection] Cannot commit to '$BRANCH'." >&2
    echo "  → Why: All work happens on feature branches for clean history and PR-based review." >&2
    echo "    Run: git checkout -b feat/your-feature." >&2
    exit 2
  fi
done

exit 0
