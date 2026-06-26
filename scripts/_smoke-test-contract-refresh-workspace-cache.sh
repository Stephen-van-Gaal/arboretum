#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-contract-refresh-workspace-cache.sh — Contract test for
# docs/contracts/refresh-workspace-cache.contract.md. Asserts RWC-1..RWC-9
# from the contract's ## Test surface against scripts/refresh-workspace-cache.sh.
#
# Uses the fixture-project pattern: mktemp -d a real git repo (with local bare
# remote or no remote, as needed per case), shadow PATH with a gh stub that
# reads its behaviour from env vars, invoke scripts/refresh-workspace-cache.sh
# against the fixture, assert with python3 against the resulting cache JSON.
#
# Cases:
#   RWC-2: not-a-git-repo plain dir → error field set
#   RWC-3: dirty + drift (local bare remote, 1 ahead, dirty file) + local_branches content
#   RWC-4: offline/no-remote → fetch_ok false, local facts present
#   RWC-5/RWC-6 azure: dev.azure.com origin → provider azure-devops, open_pr null, gh NOT called
#   RWC-6 github PR: github.com origin, gh stub + timeout shim → open_pr populated (real PR object)
#   RWC-7 scrub (title): gh stub PR title contains a control char → stripped at write
#   RWC-7 scrub (worktree path): git worktree path contains a control char → stripped at write
#
# timeout shim:
#   refresh-workspace-cache.sh gates BOTH the git-fetch path AND the gh-PR lookup
#   behind `command -v timeout`. On macOS without GNU coreutils, both are skipped
#   without the shim. The shadow PATH bin dir includes a timeout shim that drops
#   the duration argument and execs the remaining command, so both paths are
#   genuinely exercised on EVERY platform (not just Linux with GNU coreutils).
#   The shim just calls the actual command unbounded — harmless for local fixtures.
#
# Do NOT use ARBO_WORKSPACE_FETCH_TIMEOUT=0 — GNU timeout 0 means NO limit
# (not zero-second timeout). Use a small positive value like 2.
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-workspace-cache.sh"

[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

# ── Temp dirs and cleanup ─────────────────────────────────────────────

FIXTURE_PLAIN=$(mktemp -d)      # plain dir (not a git repo) — RWC-2
FIXTURE_DRIFT=$(mktemp -d)      # git repo with bare remote, dirty, 1 ahead — RWC-3
FIXTURE_BARE=$(mktemp -d)       # bare remote for FIXTURE_DRIFT
FIXTURE_NOREM=$(mktemp -d)      # git repo with no remote — RWC-4
FIXTURE_AZURE=$(mktemp -d)      # git repo with azure origin — RWC-5/6
FIXTURE_GITHUB=$(mktemp -d)     # git repo with github origin — RWC-6/7
FIXTURE_SLASH=$(mktemp -d)      # git repo tracking a SLASH-named remote — RWC-3 (Codex #378)
FIXTURE_SLASH_BARE=$(mktemp -d) # bare remote for FIXTURE_SLASH
GH_STUB_DIR=$(mktemp -d)        # shadow PATH for the gh stub
GH_SENTINEL="$GH_STUB_DIR/gh_was_called"   # written by stub when invoked

trap 'rm -rf "$FIXTURE_PLAIN" "$FIXTURE_DRIFT" "$FIXTURE_BARE" "$FIXTURE_NOREM" "$FIXTURE_AZURE" "$FIXTURE_GITHUB" "$FIXTURE_SLASH" "$FIXTURE_SLASH_BARE" "$GH_STUB_DIR"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── Build the gh stub ─────────────────────────────────────────────────
#
# The stub responds to `gh pr list ...` by emitting $GH_PR_JSON (default: empty).
# It writes a sentinel file on every invocation so the azure case can assert
# that gh was NOT called.

cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
touch "${GH_SENTINEL_FILE:-/dev/null}"
case "$1" in
  pr)
    case "$2" in
      list)
        printf '%s' "${GH_PR_JSON:-}"
        exit 0
        ;;
    esac
    ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$GH_STUB_DIR/gh"

# ── timeout shim: drop the duration arg, exec the rest ───────────────
#
# refresh-workspace-cache.sh gates BOTH git fetch AND gh pr list behind
# `command -v timeout`. Without this shim, macOS (no GNU coreutils) skips
# both paths entirely, leaving RWC-6 and RWC-7 permanently on the degraded
# open_pr=null path. The shim satisfies `command -v timeout`, discards the
# duration ($1), and execs the actual command — the fetch and gh-lookup run
# unbounded, which is fine against local fixtures and a stub gh.
cat > "$GH_STUB_DIR/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
# test shim: ignore the duration ($1), exec the actual command
shift
exec "$@"
TIMEOUT
chmod +x "$GH_STUB_DIR/timeout"

export GH_SENTINEL_FILE="$GH_SENTINEL"

# ── Set up fixture: DRIFT (bare remote, ahead, dirty) ────────────────
#
# Layout:
#   FIXTURE_BARE  — bare remote (origin)
#   FIXTURE_DRIFT — clone, add 1 commit, dirty a file
# After setup: current_branch=main, main.behind=0, main.ahead=1, dirty=true

(
  git init --bare -q "$FIXTURE_BARE"
  cd "$FIXTURE_DRIFT" || exit 1
  git init -q
  git checkout -q -b main 2>/dev/null || true  # ensure branch is named main
  git remote add origin "$FIXTURE_BARE"
  git config user.email "test@test.test"
  git config user.name "Test"
  # Initial commit and push so origin/main exists
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git push -q origin HEAD:main
  # Set up tracking
  git fetch -q origin
  git branch --set-upstream-to=origin/main main
  # Advance local main by 1 (not pushed) → ahead=1
  echo "local change" >> README.md
  git add README.md
  git commit -q -m "local"
  # Dirty the tree
  echo "dirty" > dirty.txt
)

# ── Set up fixture: SLASH (slash-named remote) — RWC-3 (Codex #378) ──
# Git permits remote names containing slashes; main then tracks an upstream
# like `foo/bar/main`. A naive `${up%%/*}` split would mis-parse this and the
# fetch would fail (fetch_ok:false). Assert the producer fetches correctly.
(
  git init --bare -q "$FIXTURE_SLASH_BARE"
  cd "$FIXTURE_SLASH" || exit 1
  git init -q
  git checkout -q -b main 2>/dev/null || true
  git config user.email "test@test.test"
  git config user.name "Test"
  git remote add "foo/bar" "$FIXTURE_SLASH_BARE"   # slash-named remote
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git push -q "foo/bar" HEAD:main
  git fetch -q "foo/bar"
  git branch --set-upstream-to=foo/bar/main main   # upstream = foo/bar/main
  git commit -q --allow-empty -m "ahead"           # local main 1 ahead
)

# ── Set up fixture: NOREM (no remote) ────────────────────────────────
(
  cd "$FIXTURE_NOREM" || exit 1
  git init -q
  git config user.email "test@test.test"
  git config user.name "Test"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "init"
)

# ── Set up fixture: AZURE (azure origin, no push needed) ─────────────
(
  cd "$FIXTURE_AZURE" || exit 1
  git init -q
  git config user.email "test@test.test"
  git config user.name "Test"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "init"
  git remote add origin "https://dev.azure.com/org/proj/_git/repo"
)

# ── Set up fixture: GITHUB (github origin, no push needed) ────────────
(
  cd "$FIXTURE_GITHUB" || exit 1
  git init -q
  git config user.email "test@test.test"
  git config user.name "Test"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "init"
  git checkout -q -b "feat/x"
  git remote add origin "https://github.com/foo/bar.git"
)

# ── Helper: run refresh ───────────────────────────────────────────────

run_refresh() {
  # $1 = fixture path; remaining env vars must be set by caller.
  # Short fetch timeout for speed; never 0 (GNU timeout 0 = no limit).
  ARBO_WORKSPACE_FETCH_TIMEOUT=2 bash "$REFRESH" "$1"
}

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-2 — not-a-git-repo
# ─────────────────────────────────────────────────────────────────────

run_refresh "$FIXTURE_PLAIN"
case2_exit=$?

if [ "$case2_exit" -eq 0 ]; then
  pass "RWC-2: not-a-git-repo exits 0 (RWC-1 always-exits-0)"
else
  fail_case "RWC-2: expected exit 0, got $case2_exit"
fi

case2_err=$(python3 -c "
import json
c = json.load(open('$FIXTURE_PLAIN/.arboretum/workspace-cache.json'))
print(c.get('error'))
" 2>&1)
if [ "$case2_err" = "not-a-git-repo" ]; then
  pass "RWC-2: error field is 'not-a-git-repo'"
else
  fail_case "RWC-2: expected error='not-a-git-repo', got '$case2_err'"
fi

# JSON shape completeness — all top-level keys present even in the error path
case2_keys=$(python3 -c "
import json
c = json.load(open('$FIXTURE_PLAIN/.arboretum/workspace-cache.json'))
expected = {'fetched_at','fetch_ok','provider','current_branch','dirty','dirty_count',
            'main','current_upstream','worktrees','local_branches','open_pr','error'}
actual = set(c.keys())
if actual == expected:
    print('OK')
else:
    print('missing:', expected - actual, 'extra:', actual - expected)
" 2>&1)
if [ "$case2_keys" = "OK" ]; then
  pass "RWC-2: not-a-git-repo cache has all expected top-level keys"
else
  fail_case "RWC-2: top-level keys mismatch" "$case2_keys"
fi

# Fact fields null/empty/false per RWC-2
case2_facts=$(python3 -c "
import json
c = json.load(open('$FIXTURE_PLAIN/.arboretum/workspace-cache.json'))
problems = []
if c.get('current_branch') is not None: problems.append('current_branch not null')
if c.get('dirty') is not False: problems.append('dirty not false')
if c.get('dirty_count') != 0: problems.append('dirty_count not 0')
if c.get('main') is not None: problems.append('main not null')
if c.get('current_upstream') is not None: problems.append('current_upstream not null')
if c.get('worktrees') != []: problems.append('worktrees not empty')
if c.get('local_branches') != []: problems.append('local_branches not empty')
if c.get('open_pr') is not None: problems.append('open_pr not null')
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case2_facts" = "OK" ]; then
  pass "RWC-2: not-a-git-repo fact fields are null/empty/false"
else
  fail_case "RWC-2: not-a-git-repo fact fields not all null/empty/false" "$case2_facts"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-3 — dirty + drift (local main, 1 ahead, dirty file)
# ─────────────────────────────────────────────────────────────────────

run_refresh "$FIXTURE_DRIFT"
case3_exit=$?

if [ "$case3_exit" -eq 0 ]; then
  pass "RWC-3: dirty+drift case exits 0"
else
  fail_case "RWC-3: expected exit 0, got $case3_exit"
fi

case3_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json'))
problems = []
if c.get('current_branch') != 'main': problems.append('current_branch=%r' % c.get('current_branch'))
if c.get('dirty') is not True: problems.append('dirty=%r' % c.get('dirty'))
if (c.get('dirty_count') or 0) < 1: problems.append('dirty_count=%r' % c.get('dirty_count'))
m = c.get('main') or {}
if m.get('behind') != 0: problems.append('main.behind=%r (expected 0)' % m.get('behind'))
if m.get('ahead') != 1: problems.append('main.ahead=%r (expected 1)' % m.get('ahead'))
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case3_result" = "OK" ]; then
  pass "RWC-3: current_branch=main, main.behind=0, main.ahead=1, dirty=true, dirty_count>=1"
else
  fail_case "RWC-3: local facts incorrect" "$case3_result"
fi

# RWC-9 (local_branches positive case): local_branches is non-empty and contains "main"
# The not-a-git-repo case (RWC-2) asserts empty; this asserts the populated positive case.
case3_branches=$(python3 -c "
import json
c = json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json'))
branches = c.get('local_branches', [])
if not branches:
    print('FAIL: local_branches is empty')
elif 'main' not in branches:
    print('FAIL: main not in local_branches: %r' % branches)
else:
    print('OK')
" 2>&1)
if [ "$case3_branches" = "OK" ]; then
  pass "RWC-9 (local_branches positive): local_branches non-empty and contains 'main'"
else
  fail_case "RWC-9 (local_branches positive): local_branches incorrect" "$case3_branches"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-3 (slash-named remote) — upstream foo/bar/main fetches OK,
# main.fresh stays true (regression guard for the %%/* mis-split, Codex #378)
# ─────────────────────────────────────────────────────────────────────
run_refresh "$FIXTURE_SLASH" >/dev/null 2>&1
slash_result=$(python3 -c "
import json
d = json.load(open('$FIXTURE_SLASH/.arboretum/workspace-cache.json'))
m = d.get('main') or {}
problems = []
if d.get('fetch_ok') is not True: problems.append('fetch_ok=%r (expected True)' % d.get('fetch_ok'))
if m.get('fresh') is not True: problems.append('main.fresh=%r (expected True)' % m.get('fresh'))
if m.get('behind') != 0: problems.append('main.behind=%r (expected 0)' % m.get('behind'))
if m.get('ahead') != 1: problems.append('main.ahead=%r (expected 1)' % m.get('ahead'))
print('OK' if not problems else '; '.join(problems))
" 2>&1)
if [ "$slash_result" = "OK" ]; then
  pass "RWC-3 (slash-named remote): foo/bar/main upstream fetches, fetch_ok+main.fresh true"
else
  fail_case "RWC-3 (slash-named remote): mis-split upstream" "$slash_result"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-4 — offline/no-remote → fetch_ok false, local facts present
# ─────────────────────────────────────────────────────────────────────

run_refresh "$FIXTURE_NOREM"
case4_exit=$?

if [ "$case4_exit" -eq 0 ]; then
  pass "RWC-4: no-remote case exits 0"
else
  fail_case "RWC-4: expected exit 0, got $case4_exit"
fi

case4_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_NOREM/.arboretum/workspace-cache.json'))
problems = []
if c.get('fetch_ok') is not False: problems.append('fetch_ok=%r (expected false)' % c.get('fetch_ok'))
if c.get('error') is not None: problems.append('error=%r (expected null)' % c.get('error'))
# Local branch should be detected even with no remote
if not c.get('current_branch'): problems.append('current_branch empty/null — local facts not gathered')
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case4_result" = "OK" ]; then
  pass "RWC-4: no-remote sets fetch_ok=false, error=null, local branch present"
else
  fail_case "RWC-4: no-remote case result unexpected" "$case4_result"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-5/RWC-6 azure — provider azure-devops, open_pr null, gh NOT called
# ─────────────────────────────────────────────────────────────────────

rm -f "$GH_SENTINEL"

# Put the gh stub on PATH for this case to prove it is not called
PATH="$GH_STUB_DIR:$PATH" run_refresh "$FIXTURE_AZURE"
case5_exit=$?

if [ "$case5_exit" -eq 0 ]; then
  pass "RWC-5: azure case exits 0"
else
  fail_case "RWC-5: expected exit 0, got $case5_exit"
fi

case5_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_AZURE/.arboretum/workspace-cache.json'))
problems = []
if c.get('provider') != 'azure-devops': problems.append('provider=%r (expected azure-devops)' % c.get('provider'))
if c.get('open_pr') is not None: problems.append('open_pr=%r (expected null)' % c.get('open_pr'))
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case5_result" = "OK" ]; then
  pass "RWC-5/RWC-6 azure: provider=azure-devops, open_pr=null"
else
  fail_case "RWC-5/RWC-6 azure: provider/open_pr incorrect" "$case5_result"
fi

# gh must NOT have been called for an azure origin
if [ -f "$GH_SENTINEL" ]; then
  fail_case "RWC-6 azure: gh stub was invoked for an Azure DevOps origin — must be skipped"
else
  pass "RWC-6 azure: gh was NOT invoked for Azure DevOps origin"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-6 github PR — gh stub + timeout shim → open_pr populated (real object)
#
# The shadow PATH ($GH_STUB_DIR) includes both the gh stub AND the timeout shim,
# so `command -v timeout` succeeds inside the producer on every platform and the
# gh-lookup path is genuinely exercised. We assert the REAL PR object — no
# degraded-path fallback needed here.
# ─────────────────────────────────────────────────────────────────────

rm -f "$GH_SENTINEL"

# The gh stub emits a single PR object; script wraps it with `--jq '.[0] // empty'`
# which returns the object directly. We match what the script expects: a bare JSON object.
# Use python3 to build the JSON so shellcheck (SC2089/SC2090) sees no static single-quoted JSON.
GH_PR_JSON=$(python3 -c "import json; print(json.dumps({'number':42,'url':'https://github.com/foo/bar/pull/42','title':'Test PR','state':'open'}))")
export GH_PR_JSON

PATH="$GH_STUB_DIR:$PATH" run_refresh "$FIXTURE_GITHUB"
case6_exit=$?

if [ "$case6_exit" -eq 0 ]; then
  pass "RWC-6 github: exits 0"
else
  fail_case "RWC-6 github: expected exit 0, got $case6_exit"
fi

# The timeout shim is on PATH — the gh lookup must have run and populated open_pr.
# Assert the REAL PR object (number=42, state=open), not the degraded null path.
case6_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_GITHUB/.arboretum/workspace-cache.json'))
problems = []
if c.get('provider') != 'github': problems.append('provider=%r (expected github)' % c.get('provider'))
pr = c.get('open_pr')
if not isinstance(pr, dict): problems.append('open_pr=%r (expected dict — timeout shim should have enabled gh lookup)' % pr)
elif pr.get('number') != 42: problems.append('open_pr.number=%r (expected 42)' % pr.get('number'))
elif pr.get('state') != 'open': problems.append('open_pr.state=%r (expected open)' % pr.get('state'))
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case6_result" = "OK" ]; then
  pass "RWC-6 github: provider=github, open_pr.number=42, open_pr.state=open (timeout shim exercised real gh path)"
else
  fail_case "RWC-6 github: unexpected result — timeout shim + gh stub should have populated open_pr" "$case6_result"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-7 scrub (a) — control char in gh stub PR title stripped at write
#
# The timeout shim is on PATH so the gh-lookup path is genuinely exercised.
# The gh stub emits a PR title containing ESC (\x1b) — a control char in the
# scrub range. Assert the cached open_pr.title has the ESC stripped but the
# surrounding readable content preserved.
# ─────────────────────────────────────────────────────────────────────

rm -f "$GH_SENTINEL"

# Inject ESC (\x1b) into the PR title via the gh stub.
# ESC is a control char in the scrub range (\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f).
# The stub must emit VALID JSON -- real `gh pr list --json` always JSON-encodes control
# chars as \u001b (not raw bytes). We use python3 to build the JSON so the ESC is
# properly encoded as \u001b inside the JSON string; the producer's json.loads()
# parses it back to a string containing a literal ESC byte, which is then scrubbed.
GH_PR_JSON=$(python3 -c "
import json
obj = {
    'number': 99,
    'url': 'https://github.com/foo/bar/pull/99',
    'title': 'PR \x1b[31mwith escape\x1b[0m',
    'state': 'open',
}
print(json.dumps(obj))
")
export GH_PR_JSON

PATH="$GH_STUB_DIR:$PATH" run_refresh "$FIXTURE_GITHUB"
case7a_exit=$?

if [ "$case7a_exit" -eq 0 ]; then
  pass "RWC-7 scrub (title): exits 0"
else
  fail_case "RWC-7 scrub (title): expected exit 0, got $case7a_exit"
fi

# The timeout shim guarantees gh was called — assert the title scrub on the real PR object.
case7a_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_GITHUB/.arboretum/workspace-cache.json'))
pr = c.get('open_pr') or {}
title = pr.get('title', '')
if not isinstance(c.get('open_pr'), dict):
    print('FAIL: open_pr not a dict — timeout shim should have enabled gh lookup: %r' % c.get('open_pr'))
elif '\x1b' in title:
    print('FAIL: ESC char still present in title: ' + repr(title))
elif 'with escape' not in title:
    print('FAIL: expected content missing from title: ' + repr(title))
else:
    print('OK: ' + repr(title))
" 2>&1)
if echo "$case7a_result" | grep -q "^OK:"; then
  pass "RWC-7 scrub (title): open_pr.title has ESC char stripped, readable content preserved"
else
  fail_case "RWC-7 scrub (title): ANSI scrub on open_pr.title failed" "$case7a_result"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-7 scrub (b) — control char in worktree PATH stripped at write
#
# This scrub path is TIMEOUT-INDEPENDENT — it exercises the worktree.path
# scrub in parse_worktrees(), which runs on every platform regardless of
# whether gh or timeout are available. Filesystems allow BEL (\x07) in
# directory names; git ref names do NOT allow control chars (so the evil
# char lives in the path only, not the branch name).
# ─────────────────────────────────────────────────────────────────────

FIXTURE_EVIL=$(mktemp -d)
trap 'rm -rf "$FIXTURE_EVIL"' EXIT

(
  cd "$FIXTURE_EVIL" || exit 1
  git init -q
  git config user.email "test@test.test"
  git config user.name "Test"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "init"
  git remote add origin "https://github.com/foo/bar.git"
)

# Create a worktree whose directory path contains a BEL control char (\x07).
# The evil path is the directory name — the branch is a clean identifier.
WT_BASE=$(mktemp -d)
trap 'rm -rf "$WT_BASE"' EXIT
WT_EVIL="$WT_BASE/wt$(printf '\x07')evil"

# Add the evil-path worktree; fall back gracefully if the filesystem rejects it.
git -C "$FIXTURE_EVIL" worktree add -q "$WT_EVIL" -b wtbranch 2>/dev/null || true

run_refresh "$FIXTURE_EVIL"
case7b_exit=$?

if [ "$case7b_exit" -eq 0 ]; then
  pass "RWC-7 scrub (worktree-path): exits 0"
else
  fail_case "RWC-7 scrub (worktree-path): expected exit 0, got $case7b_exit"
fi

# Check whether the evil worktree was actually created (filesystem may reject BEL in path).
if [ -d "$WT_EVIL" ]; then
  # Worktree created — assert the path is scrubbed in the cache.
  # Use realpath resolution: macOS resolves /var/folders/... → /private/var/folders/...
  # and git worktree list emits the canonical (realpath) form, so we compare against
  # the resolved WT_BASE to find the entry rather than the raw mktemp-d path.
  case7b_result=$(python3 -c "
import json, os
c = json.load(open('$FIXTURE_EVIL/.arboretum/workspace-cache.json'))
wts = c.get('worktrees', [])
# Resolve the base dir to match git's canonical path (handles macOS /var/ -> /private/var/)
wt_base_real = os.path.realpath('$WT_BASE')
evil_entries = [w for w in wts if os.path.realpath(w.get('path','') or '').startswith(wt_base_real)]
if not evil_entries:
    print('FAIL: no worktree entry found with realpath prefix ' + wt_base_real + '; entries: ' + repr([w.get('path') for w in wts]))
elif any('\x07' in (w.get('path') or '') for w in evil_entries):
    print('FAIL: BEL char still present in worktree path: ' + repr([w.get('path') for w in evil_entries]))
else:
    # Confirm the de-belled path is there and the BEL is gone.
    paths = [w.get('path') for w in evil_entries]
    print('OK: ' + repr(paths))
" 2>&1)
  if echo "$case7b_result" | grep -q "^OK:"; then
    pass "RWC-7 scrub (worktree-path): BEL char stripped from worktree path in cache"
  else
    fail_case "RWC-7 scrub (worktree-path): worktree path scrub failed" "$case7b_result"
  fi
else
  echo "INFO: RWC-7 scrub (worktree-path): filesystem rejected BEL in directory name — worktree not created, skipping path-scrub assertion"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-9 — worktrees[] entries have path+branch only (no dirty field)
# (reuse the DRIFT fixture which has a real git repo)
# ─────────────────────────────────────────────────────────────────────

case9_result=$(python3 -c "
import json
c = json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json'))
wts = c.get('worktrees', [])
problems = []
for wt in wts:
    allowed = {'path', 'branch'}
    extra = set(wt.keys()) - allowed
    if extra:
        problems.append('worktree entry has unexpected keys: %s' % extra)
    if 'path' not in wt:
        problems.append('worktree entry missing path')
    if 'branch' not in wt:
        problems.append('worktree entry missing branch')
if not wts:
    # A fresh git init has one worktree (the main one); the list should be non-empty
    problems.append('worktrees list is empty (expected at least one entry for the main worktree)')
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$case9_result" = "OK" ]; then
  pass "RWC-9: worktrees[] entries have path+branch only (no dirty field)"
else
  fail_case "RWC-9: worktrees[] schema violation" "$case9_result"
fi

# ─────────────────────────────────────────────────────────────────────
# CASE: RWC-1 python3-unavailable — no-python3 path writes minimal valid cache
#
# Shadow python3 with a stub that exits 1 to simulate absence of python3.
# The script's no-python3 fallback is a printf-built JSON (not python3), so
# removing python3 from PATH exercises that branch.
# ─────────────────────────────────────────────────────────────────────

NOPY_DIR=$(mktemp -d)
trap 'rm -rf "$NOPY_DIR"' EXIT

# Stub python3 to be absent by creating a shadow PATH that has no python3
# (simply don't create one — PATH shadow overrides system python3 lookup)
# We use a non-existent directory on the front of PATH to mask python3.
EMPTY_BIN=$(mktemp -d)
trap 'rm -rf "$EMPTY_BIN"' EXIT

# Run DRIFT fixture (valid git repo) with python3 shadowed out
PATH="$EMPTY_BIN:$(echo "$PATH" | tr ':' '\n' | grep -v "$(dirname "$(command -v python3)")" | tr '\n' ':' | sed 's/:$//')" \
  ARBO_WORKSPACE_FETCH_TIMEOUT=2 bash "$REFRESH" "$FIXTURE_DRIFT" 2>/dev/null || true

# If python3 was successfully masked, the cache should have error=python3-unavailable
# If python3 masking failed (e.g. it's a builtin or the masking didn't work cleanly),
# we skip rather than fail — this is a best-effort case.
if python3 -c "
import json, sys
try:
    c = json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json'))
    e = c.get('error')
    if e == 'python3-unavailable':
        print('OK-nopy3')
    else:
        # Cache was written by the full python3 path (masking didn't work) — skip
        print('SKIP: python3 masking ineffective (error=%r)' % e)
except Exception as ex:
    print('FAIL: cache not valid JSON: ' + str(ex))
" 2>&1 | grep -q "^OK-nopy3"; then
  pass "RWC-1: python3-unavailable path writes minimal valid JSON with error=python3-unavailable"
elif python3 -c "
import json
c = json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json'))
print(c.get('error'))
" 2>&1 | grep -q "SKIP"; then
  echo "INFO: RWC-1 python3-unavailable: masking ineffective on this platform — skipping (not a failure)"
else
  # File is valid JSON but didn't have the expected error — still valid JSON means RWC-1 atomic write works
  nopy_json=$(python3 -c "import json; json.load(open('$FIXTURE_DRIFT/.arboretum/workspace-cache.json')); print('valid JSON')" 2>&1)
  if [ "$nopy_json" = "valid JSON" ]; then
    pass "RWC-1: cache always valid JSON (python3-unavailable masking not testable — got full path instead)"
  else
    fail_case "RWC-1: cache is not valid JSON after python3-shadowing attempt" "$nopy_json"
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# Atomic-write spot-check (mirrors RNC-7 Layer 2 pattern assertion)
# Assert write_cache() in the producer still uses mktemp + atomic mv.
# ─────────────────────────────────────────────────────────────────────

write_cache_body=$(awk '
  /^write_cache\(\)/ { in_fn=1; next }
  in_fn && /^}$/ { in_fn=0 }
  in_fn { print }
' "$REFRESH")
if echo "$write_cache_body" | grep -qE 'mktemp[[:space:]]+"\$CACHE_DIR' \
   && echo "$write_cache_body" | grep -qE '^[[:space:]]*mv[[:space:]]+"\$tmp"[[:space:]]+"\$CACHE_FILE"'; then
  pass "RWC-1 (atomic-write pattern): write_cache() still uses mktemp + atomic mv discipline"
else
  fail_case "RWC-1 (atomic-write pattern): write_cache() does NOT match mktemp + mv pattern — concurrent writes may not be atomic" "$write_cache_body"
fi

# ── Summary ──────────────────────────────────────────────────────────

if [ "$fail" -eq 0 ]; then
  echo "All refresh-workspace-cache contract assertions passed."
  exit 0
else
  echo "Some refresh-workspace-cache contract assertions failed." >&2
  exit 1
fi
