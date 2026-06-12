#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/contracts/pre-commit-branch-check.cli-contract.md.
# Exercises CLI-1..CLI-9 via fixture scenarios (A–O) driving the
# hook directly with stdin JSON. Picked up automatically by
# ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

HOOK="$(pwd)/.claude/hooks/pre-commit-branch-check.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

# Identity flags reused across fixture inits — keeps CI runners without
# a global git config from failing at "Author identity unknown".
GIT_ID=(-c user.email=t@t -c user.name=t)

# Fixture host project: .arboretum.yml at layer 2 and a git repo on main.
HOST=$(mktemp -d)
TARGET_FEAT=$(mktemp -d)
TARGET_MAIN=$(mktemp -d)
trap 'rm -rf "$HOST" "$TARGET_FEAT" "$TARGET_MAIN" 2>/dev/null' EXIT
echo "layer: 2" > "$HOST/.arboretum.yml"
( cd "$HOST" && git init -q && git "${GIT_ID[@]}" commit -q --allow-empty -m init ) || {
  echo "FAIL: could not init host fixture repo" >&2; exit 1;
}
# Some git versions name the default branch 'master'; rename to 'main' so
# scenario C's protected-branch match is deterministic.
( cd "$HOST" && git branch -M main 2>/dev/null || true )

# Cross-repo target on a non-protected feature branch.
( cd "$TARGET_FEAT" && git init -q && git "${GIT_ID[@]}" commit -q --allow-empty -m init && git checkout -q -b feat/x ) || {
  echo "FAIL: could not init feat-target fixture repo" >&2; exit 1;
}

# Cross-repo target on a protected branch (main) — for scenario F.
( cd "$TARGET_MAIN" && git init -q && git "${GIT_ID[@]}" commit -q --allow-empty -m init ) || {
  echo "FAIL: could not init main-target fixture repo" >&2; exit 1;
}
( cd "$TARGET_MAIN" && git branch -M main 2>/dev/null || true )

fail=0

# run_permitted asserts: exit code matches expected; stdout is empty;
# stderr is empty. Pins CLI-7's zero-side-effect invariant on permitted
# paths — earlier versions of this test checked only the exit code,
# letting a hook that emitted spurious output pass trivially.
#
# Payload is piped via `printf '%s'` (literal emission, no escape
# interpretation) inside a subshell that cd's into $HOST. Earlier
# versions used `bash -c "echo '$cmd' | bash '$HOOK'"`, which embedded
# $cmd inside double-then-single quotes — fine for payloads without
# single quotes (today's A–I), brittle for any future scenario whose
# JSON contains a single quote. Subshell + pipe avoids the
# double-substitution entirely. (Security review hardening 2026-05-29.)
run_permitted() {
  local name="$1" cmd="$2" expected_rc="$3"
  local stdout_file stderr_file rc
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  ( cd "$HOST" && printf '%s' "$cmd" | CLAUDE_PROJECT_DIR="$HOST" bash "$HOOK" ) \
    >"$stdout_file" 2>"$stderr_file"
  rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: $name — expected exit $expected_rc, got $rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    fail=1
  elif [ -s "$stdout_file" ]; then
    echo "FAIL: $name — expected empty stdout, got: $(cat "$stdout_file")" >&2
    fail=1
  elif [ -s "$stderr_file" ]; then
    echo "FAIL: $name — expected empty stderr, got: $(cat "$stderr_file")" >&2
    fail=1
  else
    echo "PASS: $name (exit $rc; stdout+stderr empty)"
  fi
  rm -f "$stdout_file" "$stderr_file"
}

# run_blocked asserts: exit 2; stdout empty; stderr contains the
# documented block message. Separates stdout from stderr per CLI-7.
# Same subshell + stdin-pipe pattern as run_permitted (see comment
# there for rationale).
run_blocked() {
  local name="$1" cmd="$2"
  local stdout_file stderr_file rc
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  ( cd "$HOST" && printf '%s' "$cmd" | CLAUDE_PROJECT_DIR="$HOST" bash "$HOOK" ) \
    >"$stdout_file" 2>"$stderr_file"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "FAIL: $name — expected exit 2, got $rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    fail=1
  elif [ -s "$stdout_file" ]; then
    echo "FAIL: $name — expected empty stdout, got: $(cat "$stdout_file")" >&2
    fail=1
  elif ! grep -q "\[Branch Protection\] Cannot commit to 'main'" "$stderr_file"; then
    echo "FAIL: $name — expected stderr block message; got: $(cat "$stderr_file")" >&2
    fail=1
  else
    echo "PASS: $name (exit 2; stderr block message present)"
  fi
  rm -f "$stdout_file" "$stderr_file"
}

# Scenario A — CLI-1: trigger discipline (non-commit command, permitted, silent)
run_permitted "A: trigger discipline (git status)" \
  '{"tool_input":{"command":"git status"}}' \
  0

# Scenario B — CLI-2: layer gate (.arboretum.yml at layer 1 → silent permit)
echo "layer: 1" > "$HOST/.arboretum.yml"
run_permitted "B: layer gate (layer 1, git commit)" \
  '{"tool_input":{"command":"git commit -am test"}}' \
  0
echo "layer: 2" > "$HOST/.arboretum.yml"

# Scenario C — CLI-5 + CLI-7: in-project main block (host is on main → blocked)
run_blocked "C: in-project main block" \
  '{"tool_input":{"command":"git commit -am test"}}'

# Scenario D — CLI-3 + CLI-4: cross-repo via cd && git commit (target on feat/x → permitted, silent)
run_permitted "D: cross-repo via cd && git commit" \
  "{\"tool_input\":{\"command\":\"cd $TARGET_FEAT && git commit -am fix\"}}" \
  0

# Scenario E — CLI-3 + CLI-4: cross-repo via git -C (target on feat/x → permitted, silent)
# Exercises CLI-1's trigger expansion (this shape would not have fired
# pre-PR-5) AND CLI-3's git-C priority resolution.
run_permitted "E: cross-repo via git -C to feat/x" \
  "{\"tool_input\":{\"command\":\"git -C $TARGET_FEAT commit -am fix\"}}" \
  0

# Scenario F — CLI-3 + CLI-5: cross-repo via git -C to a protected branch.
# Switch the host to a feat/* branch first so the assertion proves the
# hook reads the *target's* branch (main), not falling back to host:
# if git-C resolution were silently broken and fell back to $PWD, the
# host would be on feat/scenario-f → permitted (exit 0) → this scenario
# would fail its blocked-assertion. Only working git-C resolution gives
# the expected exit 2 with the main-branch block message.
( cd "$HOST" && git checkout -q -b feat/scenario-f )
run_blocked "F: cross-repo via git -C to protected main" \
  "{\"tool_input\":{\"command\":\"git -C $TARGET_MAIN commit -am fix\"}}"

# Scenario J — CLI-3 + CLI-4 quote-stripping: quoted git -C target must
# resolve correctly. Pre-/land-round-1 the awk extraction preserved the
# surrounding quotes, leading to a `git -C "'/repo'"` invocation that
# fails (literal-named dir absent) and silently permits the commit.
# Host on feat/scenario-f from Scenario F — proves resolution reads the
# target. Round-1 review (Codex hook:63) surfaced the bypass.
run_blocked "J: quoted git -C target — quote-strip resolves correctly" \
  "{\"tool_input\":{\"command\":\"git -C '$TARGET_MAIN' commit -am fix\"}}"

# Scenario K — CLI-3 relative-anchor: relative git -C operand after a
# leading cd must resolve against the cd base. The wrapped command
# below targets $TARGET_MAIN/.  via the cd-anchored relative `.`;
# without the anchor fix, GIT_C_TARGET=. is evaluated from the hook's
# $PWD (host project on feat) and the protected-branch check silently
# permits the commit to main. Round-1 review (Codex hook:70) surfaced
# the bypass.
run_blocked "K: relative git -C anchored against leading cd base" \
  "{\"tool_input\":{\"command\":\"cd $TARGET_MAIN && git -C . commit -am fix\"}}"

# Scenario L — CLI-3 + CLI-4 quote-stripping: quoted cd target must
# resolve correctly. Pre-/land-round-1 the awk extraction preserved
# the quotes around the cd operand, leading to a `git -C "'/repo'"`
# invocation that fails and silently permits. Host on feat/scenario-f
# proves resolution reads the target. Round-1 review (Codex hook:68)
# surfaced the bypass.
run_blocked "L: quoted cd target — quote-strip resolves correctly" \
  "{\"tool_input\":{\"command\":\"cd '$TARGET_MAIN' && git commit -am fix\"}}"

# Scenario G — CLI-3 priority: `cd <feat>` + `git -C <main>` together.
# Both operands are present in the same command. CLI-3 promises git -C
# wins. If the implementation accidentally preferred `cd`, the resolved
# target would be feat/x (TARGET_FEAT) → permitted → this scenario
# fails the blocked-assertion. Only correct priority order (git -C
# overrides cd) gives the expected block. Host stays on feat/scenario-f
# from Scenario F — irrelevant to the assertion (resolution must read
# the target, not fall back to host) and convenient for setup.
run_blocked "G: priority — cd \$TARGET_FEAT && git -C \$TARGET_MAIN" \
  "{\"tool_input\":{\"command\":\"cd $TARGET_FEAT && git -C $TARGET_MAIN commit -am fix\"}}"

# Scenario H — CLI-3 chunked-parsing: preceding non-commit `git -C`
# must NOT be selected as the commit target. Switch host back to main
# so the actual commit (which runs in PWD=HOST on main) blocks. If the
# implementation incorrectly extracted the leading `git -C $TARGET_FEAT`
# as the target, BRANCH would be feat/x → permitted (exit 0) → this
# scenario fails the blocked-assertion. Only chunked parsing (bounding
# the -C lookup to the chunk containing `commit`) gives the expected
# block. Round-4 review surfaced the cross-chunk regex flaw.
( cd "$HOST" && git checkout -q main )
run_blocked "H: preceding non-commit git -C does not leak into resolution" \
  "{\"tool_input\":{\"command\":\"git -C $TARGET_FEAT status && git commit -am fix\"}}"

# Scenario I — CLI-2 missing config: when .arboretum.yml is absent,
# the layer-gate sed read fails under set -euo pipefail unless guarded
# with `|| echo ''`. CLI-2 promises silent exit 0 for the missing
# config case; without the guard, the hook returns 1 (sed file-open
# error propagated via pipefail). Round-4 review surfaced the gap.
mv "$HOST/.arboretum.yml" "$HOST/.arboretum.yml.bak"
run_permitted "I: missing .arboretum.yml (layer-gate no-op)" \
  '{"tool_input":{"command":"git commit -am test"}}' \
  0
mv "$HOST/.arboretum.yml.bak" "$HOST/.arboretum.yml"

# Scenario M — CLI-1 trigger boundary widened to accept shell delimiters.
# `git commit;` is a real commit invocation; the pre-/land-round-1
# boundary `([[:space:]]|$)` rejected `;` (and `|`, `)`, `&`) and the
# hook no-op'd before the branch check. Host is on main (from H), so a
# correctly-fired hook must block. Round-1 review (Copilot hook:40)
# surfaced the regression vs the pre-PR-5 substring match.
run_blocked "M: trigger boundary — git commit; echo done" \
  '{"tool_input":{"command":"git commit; echo done"}}'

# Scenario N — #624 collision advisory: a second local branch for the same
# issue yields a NON-BLOCKING [Collision] advisory (exit 0 + stderr), never a
# block. The hook resolves workspace-collision-check.sh relative to itself, so
# the real framework script runs against this fixture's branches. Asserts the
# new CLI clause: warn-reattach -> exit 0 + advisory; the sole exit-2 block
# stays the protected-branch guard (D6).
WARN=$(mktemp -d)
( cd "$WARN" && git "${GIT_ID[@]}" init -q && git "${GIT_ID[@]}" commit -q --allow-empty -m init
  git branch -M main 2>/dev/null || true
  echo "layer: 2" > .arboretum.yml
  git "${GIT_ID[@]}" branch feat/777-a
  git "${GIT_ID[@]}" branch feat/777-b
  git "${GIT_ID[@]}" checkout -q feat/777-a )
n_out=$(mktemp); n_err=$(mktemp)
( cd "$WARN" && printf '%s' '{"tool_input":{"command":"git commit -am x"}}' \
    | CLAUDE_PROJECT_DIR="$WARN" bash "$HOOK" ) >"$n_out" 2>"$n_err"
n_rc=$?
if [ "$n_rc" -eq 0 ] && [ ! -s "$n_out" ] && grep -qi 'collision' "$n_err"; then
  echo "PASS: N collision advisory non-blocking (exit 0, [Collision] on stderr)"
else
  echo "FAIL: N — expected exit 0 + [Collision] stderr; rc=$n_rc stdout=$(cat "$n_out") stderr=$(cat "$n_err")" >&2
  fail=1
fi
rm -f "$n_out" "$n_err"; rm -rf "$WARN"

# Scenario O — #390 worktrees-always permit case via the CLI-3 $PWD fallback.
# A session whose cwd is its own feature-branch tree issues a BARE `git commit`
# (no `git -C`, no `cd &&`) and must be PERMITTED, silently. This is the exact
# false-block #390 reported, now structurally prevented: under worktrees-always
# (#716) the session cwd is the feature-branch tree, so CLI-3's $PWD fallback
# resolves that tree's branch rather than the main tree's protected branch.
# #390's named `git -C`/`cd &&` shapes are already pinned by D/E; this locks the
# bare-commit case so the false-block cannot silently return.
#
# Fixture note: $HOST is a plain checkout switched to a feature branch, NOT a
# linked `git worktree`. That is deliberate and sufficient — the hook resolves
# the branch with `git -C "$PWD" rev-parse --abbrev-ref HEAD`, which reads a
# feature-branch checkout and a linked worktree identically, so the plain
# checkout faithfully exercises the worktrees-always $PWD-fallback path without
# the cost of a real worktree fixture. The branch has no issue number, so the
# CLI-8 collision read-back stays `clear` and stderr remains empty per
# run_permitted. (Host is on main from H/M.)
( cd "$HOST" && git checkout -q -b feat/scenario-o )
run_permitted "O: bare git commit on feature-branch checkout — \$PWD-fallback permits (worktrees-always, #390)" \
  '{"tool_input":{"command":"git commit -am fix"}}' \
  0

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
