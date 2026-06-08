#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-refresh-next-cache.sh — Contract test for
# docs/contracts/refresh-next-cache.contract.md. Asserts RNC-1..RNC-7
# from the contract's ## Test surface against scripts/refresh-next-cache.sh.
#
# Uses the fixture-project pattern: mktemp -d a project skeleton (with
# a git init and synthetic remote so the no_gh_remote short-circuit
# doesn't fire), shadow PATH with a gh stub that reads its behaviour
# from env vars, invoke scripts/refresh-next-cache.sh against the
# fixture, assert with grep / python3 against the resulting cache JSON.
#
# Three cases per RNC-3's three union shapes:
#   A — success path  : handoff normal dict
#   B — no-handoff    : handoff null
#   C — fetch failure : handoff error dict (closes #264)
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
#
# Closes #264 (RNC-4 comment-fetch-failure discipline) as non-recurrable
# by construction.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-next-cache.sh"

[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
GH_STUB_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$GH_STUB_DIR"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# ── Build the gh stub ────────────────────────────────────────────────
#
# The stub responds to:
#   `gh auth status`              → exit 0 (always; we test gh-unavailable
#                                   separately, not here)
#   `gh api repos/{owner}/{repo}` → exit 0 (live-access probe)
#   `gh issue list ...`           → emit $GH_STUB_ISSUES, exit 0
#   `gh issue view <N> --json comments`
#                                 → emit $GH_STUB_COMMENTS, exit $GH_STUB_COMMENTS_EXIT.
#                                   On non-zero exit, emit $GH_STUB_COMMENTS_STDERR to stderr.
#
# Per-test config via env vars set before invoking the real script.

cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
# Each subcommand has an injectable exit code + stderr so the smoke test
# can exercise the producer's three exit-code paths (0/1/2) per RNC-2.
#
# Also handles: gh api graphql (returns GH_STUB_GRAPHQL or empty graph),
# gh repo view (returns synthetic owner/name for roadmap_github_epic_graph),
# gh issue edit (records sentinel file for RNC-9 auto-advance assertion).
#
# F1 (closed next-up probe): `gh issue list --state closed ...` returns
# GH_STUB_CLOSED_ISSUES (defaults to []). When GH_STUB_ISSUES is [] (open
# list returns empty), refresh-next-cache.sh probes for a closed next-up.
# The stub differentiates --state open vs --state closed to model reality.
#
# NOTE: do NOT inline `{"comments":[]}` into a `${VAR:-default}` expansion
# — bash's nested-brace handling in parameter-expansion default values is
# asymmetric and emits a spurious trailing `}` when VAR is set. Use a
# plain variable for the default instead.
default_comments='{"comments":[]}'
default_graphql='{"data":{"repository":{"issue":null}}}'
case "$1" in
  auth)
    case "$2" in
      status)
        exit_code="${GH_STUB_AUTH_EXIT:-0}"
        if [ "$exit_code" -ne 0 ]; then
          printf '%s\n' "${GH_STUB_AUTH_STDERR:-You are not logged into any GitHub hosts.}" >&2
        fi
        exit "$exit_code"
        ;;
    esac
    ;;
  repo)
    case "$2" in
      view)
        # roadmap_github_epic_graph calls:
        #   gh repo view --json owner -q .owner.login
        #   gh repo view --json name -q .name
        for arg in "$@"; do
          case "$arg" in
            .owner.login) printf 'stub-owner\n'; exit 0 ;;
            .name) printf 'stub-repo\n'; exit 0 ;;
          esac
        done
        printf 'stub-owner/stub-repo\n'
        exit 0
        ;;
    esac
    ;;
  api)
    case "$2" in
      repos/{owner}/{repo})
        printf 'owner/repo\n'
        exit 0
        ;;
      graphql)
        # roadmap_github_epic_graph — return injected graphql response or empty graph.
        printf '%s\n' "${GH_STUB_GRAPHQL:-$default_graphql}"
        exit 0
        ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        exit_code="${GH_STUB_LIST_EXIT:-0}"
        if [ "$exit_code" -ne 0 ]; then
          printf '%s\n' "${GH_STUB_LIST_STDERR:-API rate limit exceeded for installation}" >&2
          exit "$exit_code"
        fi
        # F1: differentiate --state open vs --state closed so the closed-next-up
        # probe (refresh-next-cache.sh F1 fix) returns a different result than the
        # open fetch. Scan positional args for --state <value>.
        _state_val=""
        _i=1
        while [ "$_i" -le "$#" ]; do
          eval "_arg=\${$_i}"
          if [ "$_arg" = "--state" ]; then
            _j=$(( _i + 1 ))
            eval "_state_val=\${$_j}"
            break
          fi
          _i=$(( _i + 1 ))
        done
        if [ "$_state_val" = "closed" ]; then
          printf '%s' "${GH_STUB_CLOSED_ISSUES:-[]}"
        else
          printf '%s' "${GH_STUB_ISSUES:-[]}"
        fi
        exit 0
        ;;
      view)
        exit_code="${GH_STUB_COMMENTS_EXIT:-0}"
        if [ "$exit_code" -ne 0 ]; then
          printf '%s\n' "${GH_STUB_COMMENTS_STDERR:-HTTP 503 service unavailable}" >&2
          exit "$exit_code"
        fi
        printf '%s' "${GH_STUB_COMMENTS:-$default_comments}"
        exit 0
        ;;
      edit)
        # roadmap_tracker_issue_update → gh issue edit <N> --add-label/--remove-label
        # Write a sentinel file so the auto-advance assertion can detect the call.
        # Sentinel path is injected via GH_STUB_EDIT_SENTINEL env var.
        if [ -n "${GH_STUB_EDIT_SENTINEL:-}" ]; then
          printf '%s\n' "$*" >> "$GH_STUB_EDIT_SENTINEL"
        fi
        exit "${GH_STUB_EDIT_EXIT:-0}"
        ;;
    esac
    ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$GH_STUB_DIR/gh"

# ── Build the fixture project ────────────────────────────────────────
#
# Needs git init with a remote so refresh-next-cache.sh doesn't fire its
# `no_gh_remote: true` short-circuit. The remote URL doesn't need to point
# at anything real — refresh-next-cache.sh only checks that ANY remote
# is configured before calling gh.

( cd "$FIXTURE" && \
  git init -q && \
  git remote add origin "https://example.test/stub.git" )

# Additional surface needed for Case D (consumer rendering): session-start.sh's
# `[Next-up]` block is wrapped in `if [ -f "$NEXT_REFRESH" ]` where NEXT_REFRESH
# is "$PROJECT_DIR/scripts/refresh-next-cache.sh". Without the stub the renderer
# would silently skip the block (Codex flagged this in PR #365 review under X5).
# Also need CLAUDE.md for the hook's preamble checks.
touch "$FIXTURE/CLAUDE.md"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs"
touch "$FIXTURE/scripts/refresh-next-cache.sh"
# Pin LAYER=2 so the hook skips its Layer<2 suggestion block. Under a fresh
# `git init` with zero commits, that block's `[ "$author_count" -ge 2 ] &&
# suggest_l2=true` line triggers `set -e` (the test fails, the && short-
# circuits, the statement exits 1) and aborts the hook before its output is
# printed. Layer 2 sidesteps the whole block; the [Next-up] rendering we're
# testing here runs earlier and is unaffected by the layer pin.
echo "layer: 2" > "$FIXTURE/.arboretum.yml"

# ── Helper: run refresh and read the resulting cache ─────────────────

run_refresh() {
  # $1 = case label
  # Stub-PATH-shadowed invocation against the fixture. The script writes
  # to $FIXTURE/.arboretum/next-cache.json.
  rm -f "$FIXTURE/.arboretum/next-cache.json"
  PATH="$GH_STUB_DIR:$PATH" bash "$REFRESH" "$FIXTURE"
}

# ── Case A: success path — handoff normal dict ───────────────────────

export GH_STUB_ISSUES='[{"number":42,"title":"Test issue 42","url":"https://example.test/42","body":"Body line one.","labels":[{"name":"next-up"}],"updatedAt":"2026-05-28T00:00:00Z"}]'
export GH_STUB_COMMENTS='{"comments":[{"body":"<!-- arbo-handoff: feat/example 2026-05-28T01:00:00Z -->\n**Session handoff**\n\n→ Next action: implement the thing\n\nSome prose describing what is next.","createdAt":"2026-05-28T01:00:00Z"}]}'
export GH_STUB_COMMENTS_EXIT=0
export GH_STUB_COMMENTS_STDERR=""

run_refresh "A: success"
caseA_exit=$?

if [ "$caseA_exit" -eq 0 ]; then
  pass "RNC-2 (case A): success path exits 0"
else
  fail_case "RNC-2 (case A): expected exit 0, got $caseA_exit"
fi

# RNC-1: cache is valid JSON with the right top-level keys
caseA_keys=$(python3 -c "
import json
c = json.load(open('$FIXTURE/.arboretum/next-cache.json'))
print(sorted(c.keys()))
" 2>&1)
if [ "$caseA_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case A): cache has exactly the expected top-level keys"
else
  fail_case "RNC-1 (case A): unexpected top-level keys" "$caseA_keys"
fi

# RNC-3 (shape 2): handoff is a normal dict with expected keys
caseA_handoff_type=$(python3 -c "
import json
c = json.load(open('$FIXTURE/.arboretum/next-cache.json'))
h = c.get('handoff')
if isinstance(h, dict) and 'error' not in h and set(h.keys()) == {'posted_at','branch','next_action','body'}:
    print('OK normal-dict')
else:
    print('BAD', repr(h))
")
if [ "$caseA_handoff_type" = "OK normal-dict" ]; then
  pass "RNC-3 (case A): handoff is a normal-dict union shape with expected keys"
else
  fail_case "RNC-3 (case A): handoff shape unexpected" "$caseA_handoff_type"
fi

# Sanity: next_action and body parsed correctly
caseA_na=$(python3 -c "
import json
print(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['handoff']['next_action'])
")
if [ "$caseA_na" = "implement the thing" ]; then
  pass "RNC-3 (case A): next_action extracted from arbo-handoff comment"
else
  fail_case "RNC-3 (case A): next_action not extracted correctly" "got: $caseA_na"
fi

# ── Case B: no-handoff path — handoff null ───────────────────────────

export GH_STUB_COMMENTS='{"comments":[]}'
export GH_STUB_COMMENTS_EXIT=0

run_refresh "B: no-handoff"
caseB_exit=$?

if [ "$caseB_exit" -eq 0 ]; then
  pass "RNC-2 (case B): no-handoff path exits 0"
else
  fail_case "RNC-2 (case B): expected exit 0, got $caseB_exit"
fi

caseB_handoff=$(python3 -c "
import json
print(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['handoff'])
")
if [ "$caseB_handoff" = "None" ]; then
  pass "RNC-3 (case B): handoff is null when no arbo-handoff comment exists"
else
  fail_case "RNC-3 (case B): expected handoff=None, got $caseB_handoff"
fi

# RNC-1 (case B): exact top-level key set
caseB_keys=$(python3 -c "
import json
print(sorted(json.load(open('$FIXTURE/.arboretum/next-cache.json')).keys()))
")
if [ "$caseB_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case B): cache has exactly the expected top-level keys"
else
  fail_case "RNC-1 (case B): unexpected top-level keys" "$caseB_keys"
fi

# ── Case C: comment-fetch-failure path — handoff error dict ──────────
#
# This is the bug-close case. Inject an ANSI-escape-laced stderr message
# to also exercise RNC-6 ANSI-scrub on the detail field.

export GH_STUB_COMMENTS=''
export GH_STUB_COMMENTS_EXIT=1
# Embedded literal ESC \x1b for the synthetic ANSI escape sequence.
export GH_STUB_COMMENTS_STDERR=$'HTTP 503 \x1b[31mservice unavailable\x1b[0m'

run_refresh "C: comment-fetch failure"
caseC_exit=$?

# RNC-2: exit 0 even on comment-fetch failure (the failure is in-cache,
# not about-cache). This is the most important exit-code assertion in
# this contract — it pins the design D6 decision.
if [ "$caseC_exit" -eq 0 ]; then
  pass "RNC-2 (case C, design D6): comment-fetch failure still exits 0 (failure recorded in-cache)"
else
  fail_case "RNC-2 (case C): expected exit 0 on comment-fetch failure, got $caseC_exit (was the script's exit-code handling regressed?)"
fi

# RNC-4: handoff is the error-dict variant, NOT null
caseC_handoff_shape=$(python3 -c "
import json
c = json.load(open('$FIXTURE/.arboretum/next-cache.json'))
h = c.get('handoff')
if isinstance(h, dict) and h.get('error') == 'fetch-failed' and 'detail' in h:
    print('OK error-dict')
elif h is None:
    print('REGRESSION: handoff is null on comment-fetch failure (#264 reintroduced)')
else:
    print('BAD', repr(h))
")
if [ "$caseC_handoff_shape" = "OK error-dict" ]; then
  pass "RNC-4 (case C, closes #264): comment-fetch failure produces handoff error-dict, not null"
else
  fail_case "RNC-4 (case C, closes #264): handoff shape unexpected on comment-fetch failure" "$caseC_handoff_shape"
fi

# RNC-5: whole-cache `error` MUST be null (failure is scoped to handoff)
caseC_whole_err=$(python3 -c "
import json
print(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['error'])
")
if [ "$caseC_whole_err" = "None" ]; then
  pass "RNC-5 (case C): comment-fetch failure does NOT set whole-cache error"
else
  fail_case "RNC-5 (case C): whole-cache error should be null, got $caseC_whole_err"
fi

# RNC-1 (case C): exact top-level key set
caseC_keys=$(python3 -c "
import json
print(sorted(json.load(open('$FIXTURE/.arboretum/next-cache.json')).keys()))
")
if [ "$caseC_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case C): cache has exactly the expected top-level keys"
else
  fail_case "RNC-1 (case C): unexpected top-level keys" "$caseC_keys"
fi

# RNC-6: ANSI-scrub on detail. The injected stderr has \x1b[31m and \x1b[0m
# escape sequences. The scrub regex strips \x1b (the introducer) plus other
# control chars; the bracketed metacharacters [31m and [0m are NOT stripped
# (they're printable ASCII). So the expected scrubbed value contains the
# bracket text but not the \x1b bytes.
caseC_detail=$(python3 -c "
import json
print(repr(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['handoff']['detail']))
")
# The repr should not contain '\\x1b' or the literal ESC character.
if echo "$caseC_detail" | grep -qF '\x1b'; then
  fail_case "RNC-6 (case C): handoff.detail contains a \\x1b escape byte — ANSI scrub failed" "$caseC_detail"
else
  pass "RNC-6 (case C): handoff.detail has no \\x1b escape bytes (ANSI scrub applied)"
fi
# Sanity-check the surviving content
if echo "$caseC_detail" | grep -qF "HTTP 503"; then
  pass "RNC-6 (case C): handoff.detail preserves non-control content"
else
  fail_case "RNC-6 (case C): handoff.detail missing expected content" "$caseC_detail"
fi

# RNC-7: atomic-write invariant — two-layer assertion.
#
# Layer 1 (behavioural): run two refreshes in quick succession, assert the
# final cache parses as valid JSON. Sequential, not parallel (parallel is
# flaky on shared CI runners). This catches the most obvious regression class
# (truncated writes from a non-atomic implementation under fast back-to-back
# refresh).
#
# Layer 2 (implementation-pattern): grep the producer's source to assert the
# write_cache() helper still uses `mktemp` + atomic `mv`. The behavioural test
# alone could pass against a naive `printf > "$CACHE_FILE"` implementation
# under sequential load while still corrupting the cache when the session-start
# background refresh races /handoff (the actual concurrency hazard from the
# atomic-write rationale at L73-84). The pattern check is the cheap defense
# against a regression to truncate/write. (Codex round-2 finding.)
run_refresh "C-bis: second run"
run_refresh "C-tris: third run"
if python3 -c "import json; json.load(open('$FIXTURE/.arboretum/next-cache.json'))" 2>/dev/null; then
  pass "RNC-7 (Layer 1, behavioural): cache file is valid JSON after sequential rapid refreshes"
else
  fail_case "RNC-7 (Layer 1, behavioural): cache file is invalid JSON after sequential rapid refreshes"
fi

# Layer 2: implementation pattern. Extract the write_cache() function body
# (between its `()` opener and the matching closing `}`) and assert it
# contains both `mktemp` and `mv`. Strips the doc-comments around the
# function — the assertion is on the code, not the prose.
write_cache_body=$(awk '
  /^write_cache\(\)/ { in_fn=1; next }
  in_fn && /^}$/ { in_fn=0 }
  in_fn { print }
' "$REFRESH")
if echo "$write_cache_body" | grep -qE 'mktemp[[:space:]]+"\$CACHE_DIR' \
   && echo "$write_cache_body" | grep -qE '^[[:space:]]*mv[[:space:]]+"\$tmp"[[:space:]]+"\$CACHE_FILE"'; then
  pass "RNC-7 (Layer 2, pattern): write_cache() still uses mktemp + atomic mv discipline"
else
  fail_case "RNC-7 (Layer 2, pattern): write_cache() does NOT match the expected mktemp + mv pattern — concurrent writes may not be atomic" "$write_cache_body"
fi

# ── Case D: consumer rendering of Case C cache ───────────────────────
#
# Invokes .claude/hooks/session-start.sh against the fixture (which still
# carries Case C's error-union cache from the last run_refresh). Asserts
# the [Next-up] block surfaces the explicit "(handoff fetch failed ...)"
# diagnostic — pins the consumer-side isinstance branch from Task 2 D3
# as non-recurrable. Codex flagged this gap in PR #365 review (X4): without
# this case, removing the isinstance branch at the consumer would not be
# caught by any contract test.

HOOK="$(cd "$(dirname "$REFRESH")/../.claude/hooks" && pwd)/session-start.sh"
if [ ! -f "$HOOK" ]; then
  # Plugin-installed layout — hook lives under the plugin cache. Skip the
  # consumer assertion in that case rather than fail (the assertion is most
  # useful in arboretum-dev where the hook source is in-tree).
  echo "INFO: session-start.sh not found at expected path; skipping Case D"
else
  consumer_out=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$HOOK" 2>&1 || true)
  if echo "$consumer_out" | grep -qF "handoff fetch failed"; then
    pass "RNC-4 (case D, closes #264 at consumer): renderer surfaces diagnostic for error-union cache"
  else
    fail_case "RNC-4 (case D): consumer did not surface handoff-fetch-failed diagnostic" "$consumer_out"
  fi
  # The issue's title should still render — the producer's error scope is
  # handoff-only, and the consumer must continue to render the issue normally.
  if echo "$consumer_out" | grep -qF "Test issue 42"; then
    pass "RNC-4 (case D): consumer continues rendering issue title despite handoff error"
  else
    fail_case "RNC-4 (case D): issue title missing from consumer output (renderer is suppressing too much)" "$consumer_out"
  fi
fi

# ── Case E: gh unavailable — exit code 1 ─────────────────────────────
#
# Auth failure path. gh exists on PATH (the stub IS gh) but `gh auth status`
# exits non-zero — script writes whole-cache error "gh-unavailable" and
# exits 1 (RNC-2). Pins the auth-detection path against regression.

export GH_STUB_AUTH_EXIT=1
export GH_STUB_AUTH_STDERR="You are not logged into any GitHub hosts."
# Issue list / view env vars don't matter — the script exits before reaching them.

run_refresh "E: gh unavailable"
caseE_exit=$?

if [ "$caseE_exit" -eq 1 ]; then
  pass "RNC-2 (case E): gh-unavailable path exits 1"
else
  fail_case "RNC-2 (case E): expected exit 1 on gh-auth failure, got $caseE_exit"
fi

caseE_err=$(python3 -c "
import json
print(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['error'])
")
if [ "$caseE_err" = "gh-unavailable" ]; then
  pass "RNC-5 (case E): gh-unavailable failure sets whole-cache error correctly"
else
  fail_case "RNC-5 (case E): expected whole-cache error='gh-unavailable', got $caseE_err"
fi

# RNC-1 (case E): exact top-level key set — CRITICAL for early-return path.
# This is one of the two cases where the X1 fix's `"handoff": null` additions
# get exercised; without this assertion a future regression that drops the
# new line in the gh-unavailable printf block would still pass CI. (Codex
# round-2 finding.)
caseE_keys=$(python3 -c "
import json
print(sorted(json.load(open('$FIXTURE/.arboretum/next-cache.json')).keys()))
")
if [ "$caseE_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case E): early-return cache (gh-unavailable) has exactly the expected top-level keys (pins X1 fix against regression)"
else
  fail_case "RNC-1 (case E): early-return cache missing expected keys — X1 fix may have regressed in the gh-unavailable printf block" "$caseE_keys"
fi

# Reset for Case F.
export GH_STUB_AUTH_EXIT=0
unset GH_STUB_AUTH_STDERR

# ── Case F: gh issue list fails — exit code 2 ────────────────────────
#
# Primary list-call failure path (not the "not a github repository" sub-case,
# which writes no_gh_remote=true and exits 0; that's separately covered by
# the no-remote handling). A generic API failure: script writes whole-cache
# error "gh-call-failed" and exits 2 (RNC-2). Stderr does NOT match the
# "no github remote" regex, so the script falls through to the error path.

export GH_STUB_LIST_EXIT=1
export GH_STUB_LIST_STDERR="API rate limit exceeded for installation."

run_refresh "F: gh list failure"
caseF_exit=$?

if [ "$caseF_exit" -eq 2 ]; then
  pass "RNC-2 (case F): gh-list-failure path exits 2"
else
  fail_case "RNC-2 (case F): expected exit 2 on gh-list failure, got $caseF_exit"
fi

caseF_err=$(python3 -c "
import json
print(json.load(open('$FIXTURE/.arboretum/next-cache.json'))['error'])
")
if [ "$caseF_err" = "gh-call-failed" ]; then
  pass "RNC-5 (case F): gh-list failure sets whole-cache error correctly"
else
  fail_case "RNC-5 (case F): expected whole-cache error='gh-call-failed', got $caseF_err"
fi

# RNC-1 (case F): exact top-level key set — CRITICAL for early-return path.
# Pairs with case E to fully exercise the X1 fix in both early-return branches
# (auth failure at L113-118/L124-129 and list failure at L163-169). Without
# this assertion, a regression in the gh-call-failed printf block that drops
# "handoff": null would still pass CI.
caseF_keys=$(python3 -c "
import json
print(sorted(json.load(open('$FIXTURE/.arboretum/next-cache.json')).keys()))
")
if [ "$caseF_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case F): early-return cache (gh-call-failed) has exactly the expected top-level keys (pins X1 fix against regression)"
else
  fail_case "RNC-1 (case F): early-return cache missing expected keys — X1 fix may have regressed in the gh-call-failed printf block" "$caseF_keys"
fi

# Reset.
export GH_STUB_LIST_EXIT=0
unset GH_STUB_LIST_STDERR

# ── Case G: RNC-8 — epics_in_flight present in cache ────────────────
#
# The gh stub returns a minimal GraphQL response: next-up #305 is open,
# its parent is epic #295 (with children #305 open + #306 open).
# epic-walk.sh's live mode calls gh api graphql; the stub returns the raw
# GraphQL shape that roadmap_github_epic_graph's python flattener consumes.
# Since roadmap_github_epic_graph's python core reads raw GraphQL JSON (not
# graph JSON), the easiest seam here is to inject via GH_STUB_GRAPHQL a
# response whose issue.parent chain produces the expected graph, OR to use
# the epic-walk --graph-file seam instead of the live call.
#
# Strategy: inject a GRAPH_FILE path via an env var override by writing a
# custom epic-walk wrapper in the stub bin that passes --graph-file. This is
# simpler than constructing a valid raw GraphQL fixture and avoids coupling
# the test to roadmap_github_epic_graph's internal parsing logic.
# The wrapper replaces epic-walk.sh invocation in the stub environment.

G_GRAPH_FILE=$(mktemp)
# Graph: next-up #305 open under epic #295; #306 also open.
printf '%s\n' '{
  "next_up": 305,
  "nodes": {
    "295": {"number":295,"is_epic":true,"state":"open","title":"pipeline overhaul","labels":[],"parent":null,"children":[305,306],"stage":null},
    "305": {"number":305,"is_epic":false,"state":"open","title":"WS7 intake","labels":[],"parent":295,"children":[],"stage":"/build"},
    "306": {"number":306,"is_epic":false,"state":"open","title":"WS8 orphan","labels":[],"parent":295,"children":[],"stage":null}
  }
}' > "$G_GRAPH_FILE"

# Override: write a temporary epic-walk.sh in a shadowed roadmap/ bin that
# overrides the live call, passing --graph-file with the pre-baked fixture.
REAL_WALK="$SCRIPT_DIR/roadmap/epic-walk.sh"
G_ROADMAP_STUB_DIR=$(mktemp -d)
cat > "$G_ROADMAP_STUB_DIR/epic-walk.sh" <<EWSTUB
#!/usr/bin/env bash
# RNC-8 stub: always return the pre-baked graph result.
exec bash "$REAL_WALK" --graph-file "$G_GRAPH_FILE"
EWSTUB
chmod +x "$G_ROADMAP_STUB_DIR/epic-walk.sh"

# Create a fixture project for case G with the stub roadmap dir symlinked.
G_FIXTURE=$(mktemp -d)
( cd "$G_FIXTURE" && git init -q && git remote add origin "https://example.test/stub.git" )
touch "$G_FIXTURE/CLAUDE.md"
mkdir -p "$G_FIXTURE/scripts"
touch "$G_FIXTURE/scripts/refresh-next-cache.sh"
echo "layer: 2" > "$G_FIXTURE/.arboretum.yml"

# Run refresh with PATH-shadowed gh and the stub epic-walk.sh in scripts/roadmap/.
# We need scripts/roadmap/epic-walk.sh to be our stub. Create a scripts/roadmap/
# dir in the fixture with the stub, then set SCRIPT_DIR override.
# The real refresh-next-cache.sh uses SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"".
# We can't easily redirect SCRIPT_DIR. Instead, create a sibling roadmap/ dir
# next to a copy of refresh-next-cache.sh:
G_BIN=$(mktemp -d)
cp "$SCRIPT_DIR/refresh-next-cache.sh" "$G_BIN/"
mkdir -p "$G_BIN/lib"
cp "$SCRIPT_DIR/lib/scrub-control-chars.sh" "$G_BIN/lib/"
mkdir -p "$G_BIN/roadmap"
cp "$SCRIPT_DIR/roadmap/lib.sh" "$G_BIN/roadmap/"
cp "$G_ROADMAP_STUB_DIR/epic-walk.sh" "$G_BIN/roadmap/"

export GH_STUB_ISSUES='[{"number":305,"title":"WS7 intake","url":"https://example.test/305","body":"","labels":[{"name":"next-up"}],"updatedAt":"2026-06-05T00:00:00Z"}]'
export GH_STUB_COMMENTS='{"comments":[]}'
export GH_STUB_COMMENTS_EXIT=0
unset GH_STUB_EDIT_SENTINEL

PATH="$GH_STUB_DIR:$PATH" bash "$G_BIN/refresh-next-cache.sh" "$G_FIXTURE"
caseG_exit=$?

if [ "$caseG_exit" -eq 0 ]; then
  pass "RNC-2 (case G): epics_in_flight path exits 0"
else
  fail_case "RNC-2 (case G): expected exit 0, got $caseG_exit"
fi

# RNC-8: epics_in_flight is present and #295 appears
caseG_result=$(python3 -c "
import json
c = json.load(open('$G_FIXTURE/.arboretum/next-cache.json'))
assert 'epics_in_flight' in c, 'epics_in_flight key missing'
assert isinstance(c['epics_in_flight'], list), 'epics_in_flight is not a list'
nums = [e['number'] for e in c['epics_in_flight']]
assert 295 in nums, f'295 not in epics_in_flight: {nums}'
assert 'auto_advanced' in c, 'auto_advanced key missing'
print('OK')
" 2>&1)
if [ "$caseG_result" = "OK" ]; then
  pass "RNC-8 (case G): epics_in_flight present and contains #295; auto_advanced key present"
else
  fail_case "RNC-8 (case G): epics_in_flight assertion failed" "$caseG_result"
fi

# RNC-8: auto_advanced is null (next-up #305 is OPEN — no advance should fire)
caseG_auto=$(python3 -c "
import json
c = json.load(open('$G_FIXTURE/.arboretum/next-cache.json'))
print(repr(c.get('auto_advanced')))
")
if [ "$caseG_auto" = "None" ]; then
  pass "RNC-8 (case G): auto_advanced is null when next-up is open (no advance)"
else
  fail_case "RNC-8 (case G): expected auto_advanced=None when next-up is open, got $caseG_auto"
fi

# Cleanup case G temps
rm -rf "$G_ROADMAP_STUB_DIR" "$G_BIN" "$G_FIXTURE"
rm -f "$G_GRAPH_FILE"

# ── Case H: RNC-9 — auto-advance one-shot when next-up is CLOSED ─────
#
# Graph: next-up #305 is CLOSED; sibling #306 is open and ready.
# The resolver should return auto_advance={from:305,to:306,epic:295}.
# The stub's `gh issue edit` handler appends to a sentinel file.
# Assertions: auto_advanced.to==306 in cache AND sentinel exists.

H_GRAPH_FILE=$(mktemp)
printf '%s\n' '{
  "next_up": 305,
  "nodes": {
    "295": {"number":295,"is_epic":true,"state":"open","title":"pipeline overhaul","labels":[],"parent":null,"children":[305,306],"stage":null},
    "305": {"number":305,"is_epic":false,"state":"closed","title":"WS7 intake","labels":[],"parent":295,"children":[],"stage":null},
    "306": {"number":306,"is_epic":false,"state":"open","title":"WS8 orphan","labels":[],"parent":295,"children":[],"stage":null}
  }
}' > "$H_GRAPH_FILE"

H_BIN=$(mktemp -d)
H_FIXTURE=$(mktemp -d)
H_SENTINEL=$(mktemp)
# Start with empty sentinel (just needs to exist for the assertion check to work)
: > "$H_SENTINEL"

cp "$SCRIPT_DIR/refresh-next-cache.sh" "$H_BIN/"
mkdir -p "$H_BIN/lib"
cp "$SCRIPT_DIR/lib/scrub-control-chars.sh" "$H_BIN/lib/"
mkdir -p "$H_BIN/roadmap"
cp "$SCRIPT_DIR/roadmap/lib.sh" "$H_BIN/roadmap/"

# epic-walk stub: returns closed-#305 graph so auto_advance fires
cat > "$H_BIN/roadmap/epic-walk.sh" <<HWSTUB
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/roadmap/epic-walk.sh" --graph-file "$H_GRAPH_FILE"
HWSTUB
chmod +x "$H_BIN/roadmap/epic-walk.sh"

( cd "$H_FIXTURE" && git init -q && git remote add origin "https://example.test/stub.git" )
touch "$H_FIXTURE/CLAUDE.md"
mkdir -p "$H_FIXTURE/scripts"
touch "$H_FIXTURE/scripts/refresh-next-cache.sh"
echo "layer: 2" > "$H_FIXTURE/.arboretum.yml"

# F1 (reality model): the open list returns [] because #305 is now CLOSED.
# The closed probe returns #305. This is the correct model — the old test had
# GH_STUB_ISSUES returning an open issue which cannot trigger the closed-probe path.
export GH_STUB_ISSUES='[]'
export GH_STUB_CLOSED_ISSUES='[{"number":305,"title":"WS7 intake","url":"https://example.test/305","body":"","labels":[{"name":"next-up"}],"updatedAt":"2026-06-05T00:00:00Z"}]'
export GH_STUB_COMMENTS='{"comments":[]}'
export GH_STUB_COMMENTS_EXIT=0
export GH_STUB_EDIT_SENTINEL="$H_SENTINEL"
export GH_STUB_EDIT_EXIT=0

PATH="$GH_STUB_DIR:$PATH" bash "$H_BIN/refresh-next-cache.sh" "$H_FIXTURE"
caseH_exit=$?

if [ "$caseH_exit" -eq 0 ]; then
  pass "RNC-9 (case H): auto-advance path exits 0 (fail-soft)"
else
  fail_case "RNC-9 (case H): expected exit 0, got $caseH_exit"
fi

# RNC-9: auto_advanced.to == 306 in the cache
caseH_auto=$(python3 -c "
import json
c = json.load(open('$H_FIXTURE/.arboretum/next-cache.json'))
a = c.get('auto_advanced')
if a is None:
    print('FAIL: auto_advanced is null')
elif a.get('to') != 306:
    print(f'FAIL: auto_advanced.to={a.get(\"to\")} want 306')
else:
    print('OK')
" 2>&1)
if [ "$caseH_auto" = "OK" ]; then
  pass "RNC-9 (case H): auto_advanced.to==306 in cache (advance was written)"
else
  fail_case "RNC-9 (case H): auto_advanced.to unexpected" "$caseH_auto"
fi

# RNC-9: the stub received `gh issue edit ... --add-label next-up` THEN
# `gh issue edit ... --remove-label next-up` (F2: add-first ordering).
if grep -q "\-\-add-label next-up" "$H_SENTINEL" 2>/dev/null; then
  pass "RNC-9 (case H): gh issue edit --add-label next-up was called (label move confirmed)"
else
  fail_case "RNC-9 (case H): sentinel file did not record --add-label next-up call" "$(cat "$H_SENTINEL" 2>/dev/null || echo '(empty)')"
fi
if grep -q "\-\-remove-label next-up" "$H_SENTINEL" 2>/dev/null; then
  pass "RNC-9 (case H): gh issue edit --remove-label next-up was called (label removed from closed issue)"
else
  fail_case "RNC-9 (case H): sentinel file did not record --remove-label next-up call" "$(cat "$H_SENTINEL" 2>/dev/null || echo '(empty)')"
fi
# F2 ordering: assert add line appears before remove line in the sentinel.
_add_line=$(grep -n "\-\-add-label next-up" "$H_SENTINEL" 2>/dev/null | head -1 | cut -d: -f1 || true)
_rm_line=$(grep -n "\-\-remove-label next-up" "$H_SENTINEL" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -n "$_add_line" ] && [ -n "$_rm_line" ] && [ "$_add_line" -lt "$_rm_line" ]; then
  pass "RNC-9 (case H, F2): --add-label called before --remove-label (add-first ordering)"
elif [ -n "$_add_line" ] && [ -n "$_rm_line" ]; then
  fail_case "RNC-9 (case H, F2): --remove-label appeared before --add-label in sentinel — F2 add-first ordering violated" "$(cat "$H_SENTINEL" 2>/dev/null || echo '(empty)')"
fi

# RNC-9: auto-advance is fail-soft — when gh issue edit fails, exit code stays 0
# and auto_advanced is null in cache.
H2_SENTINEL=$(mktemp)
: > "$H2_SENTINEL"
H2_FIXTURE=$(mktemp -d)
H2_BIN=$(mktemp -d)

cp "$SCRIPT_DIR/refresh-next-cache.sh" "$H2_BIN/"
mkdir -p "$H2_BIN/lib"
cp "$SCRIPT_DIR/lib/scrub-control-chars.sh" "$H2_BIN/lib/"
mkdir -p "$H2_BIN/roadmap"
cp "$SCRIPT_DIR/roadmap/lib.sh" "$H2_BIN/roadmap/"
cat > "$H2_BIN/roadmap/epic-walk.sh" <<H2WSTUB
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/roadmap/epic-walk.sh" --graph-file "$H_GRAPH_FILE"
H2WSTUB
chmod +x "$H2_BIN/roadmap/epic-walk.sh"

( cd "$H2_FIXTURE" && git init -q && git remote add origin "https://example.test/stub.git" )
touch "$H2_FIXTURE/CLAUDE.md"
mkdir -p "$H2_FIXTURE/scripts"
touch "$H2_FIXTURE/scripts/refresh-next-cache.sh"
echo "layer: 2" > "$H2_FIXTURE/.arboretum.yml"

export GH_STUB_EDIT_SENTINEL="$H2_SENTINEL"
export GH_STUB_EDIT_EXIT=1   # label write FAILS

PATH="$GH_STUB_DIR:$PATH" bash "$H2_BIN/refresh-next-cache.sh" "$H2_FIXTURE"
caseH2_exit=$?

if [ "$caseH2_exit" -eq 0 ]; then
  pass "RNC-9 (case H2, fail-soft): auto-advance label write failure still exits 0"
else
  fail_case "RNC-9 (case H2, fail-soft): expected exit 0 on label write failure, got $caseH2_exit"
fi

caseH2_auto=$(python3 -c "
import json
c = json.load(open('$H2_FIXTURE/.arboretum/next-cache.json'))
a = c.get('auto_advanced')
print('None' if a is None else repr(a))
" 2>&1)
if [ "$caseH2_auto" = "None" ]; then
  pass "RNC-9 (case H2, fail-soft): auto_advanced is null when label write fails (no false ⤴)"
else
  fail_case "RNC-9 (case H2, fail-soft): auto_advanced should be null on write failure, got $caseH2_auto"
fi

# H2: F2 fix — add-first order means if --add-label fails, --remove-label is
# NOT attempted (source keeps next-up — safe). Assert that --add-label was
# attempted (proves gh was called) but --remove-label was NOT (proves F2 ordering).
if grep -q -- '--add-label next-up' "$H2_SENTINEL" 2>/dev/null; then
  pass "RNC-9 (case H2, fail-soft): --add-label next-up was attempted (add-first ordering confirmed)"
else
  fail_case "RNC-9 (case H2, fail-soft): --add-label next-up not found in H2 sentinel — gh may have been short-circuited" "$(cat "$H2_SENTINEL" 2>/dev/null || echo '(empty)')"
fi
if grep -q -- '--remove-label' "$H2_SENTINEL" 2>/dev/null; then
  fail_case "RNC-9 (case H2, fail-soft, F2): --remove-label found in sentinel but add-first ordering means it should NOT be attempted when add fails" "$(cat "$H2_SENTINEL" 2>/dev/null || echo '(empty)')"
else
  pass "RNC-9 (case H2, fail-soft, F2): --remove-label not attempted when --add-label failed (add-first safety: source keeps next-up)"
fi

# Cleanup
rm -rf "$H_BIN" "$H_FIXTURE" "$H2_BIN" "$H2_FIXTURE"
rm -f "$H_GRAPH_FILE" "$H_SENTINEL" "$H2_SENTINEL"
unset GH_STUB_EDIT_SENTINEL GH_STUB_EDIT_EXIT

# ── Case I: RNC-10 — blocked-epic context preserved when no advance ───
#
# Fix B (issue #562): when the closed next-up's epic has only blocked
# children (no ready sibling → auto_advance is null), the resolver still
# returns a non-empty epics_in_flight. Previously run_epic_walk_and_cache_if_advance
# returned 0 without writing the cache, and the caller wrote the standard
# empty cache — dropping the blocked-epic context entirely.
#
# The fix: when _auto_to/_auto_from are empty but epics_in_flight is non-empty,
# write a cache with that epics_in_flight (issue:null, auto_advanced:null) so
# the boot banner can surface the blocked-epic state.
#
# Graph: closed next-up #451, parent epic #446, only child is #451 (blocked).
# No ready sibling → auto_advance:null. epic-walk returns epics_in_flight=[#446]
# with blocked=[#451]. The resulting cache must have:
#   epics_in_flight non-empty (contains #446)
#   auto_advanced null
#   issue null

I_GRAPH_FILE=$(mktemp)
printf '%s\n' '{
  "next_up": 451,
  "nodes": {
    "446": {"number":446,"is_epic":true,"state":"open","title":"token-efficient docs","labels":[],"parent":null,"children":[451,452],"stage":null},
    "451": {"number":451,"is_epic":false,"state":"closed","title":"WS5: explicit read contracts","labels":[],"parent":446,"children":[],"stage":null},
    "452": {"number":452,"is_epic":false,"state":"open","title":"WS6: blocked work","labels":["blocked"],"parent":446,"children":[],"stage":null}
  }
}' > "$I_GRAPH_FILE"

I_BIN=$(mktemp -d)
I_FIXTURE=$(mktemp -d)

cp "$SCRIPT_DIR/refresh-next-cache.sh" "$I_BIN/"
mkdir -p "$I_BIN/lib"
cp "$SCRIPT_DIR/lib/scrub-control-chars.sh" "$I_BIN/lib/"
mkdir -p "$I_BIN/roadmap"
cp "$SCRIPT_DIR/roadmap/lib.sh" "$I_BIN/roadmap/"

# epic-walk stub: returns the all-blocked graph (closed #451, only blocked child)
cat > "$I_BIN/roadmap/epic-walk.sh" <<IWSTUB
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/roadmap/epic-walk.sh" --graph-file "$I_GRAPH_FILE"
IWSTUB
chmod +x "$I_BIN/roadmap/epic-walk.sh"

( cd "$I_FIXTURE" && git init -q && git remote add origin "https://example.test/stub.git" )
touch "$I_FIXTURE/CLAUDE.md"
mkdir -p "$I_FIXTURE/scripts"
touch "$I_FIXTURE/scripts/refresh-next-cache.sh"
echo "layer: 2" > "$I_FIXTURE/.arboretum.yml"

# F1: open list is empty (next-up #451 is CLOSED); closed probe returns #451.
export GH_STUB_ISSUES='[]'
export GH_STUB_CLOSED_ISSUES='[{"number":451,"title":"WS5: explicit read contracts","url":"https://example.test/451","body":"","labels":[{"name":"next-up"}],"updatedAt":"2026-06-05T00:00:00Z"}]'
export GH_STUB_COMMENTS='{"comments":[]}'
export GH_STUB_COMMENTS_EXIT=0
unset GH_STUB_EDIT_SENTINEL

PATH="$GH_STUB_DIR:$PATH" bash "$I_BIN/refresh-next-cache.sh" "$I_FIXTURE"
caseI_exit=$?

if [ "$caseI_exit" -eq 0 ]; then
  pass "RNC-10 (case I): blocked-epic-no-advance path exits 0"
else
  fail_case "RNC-10 (case I): expected exit 0, got $caseI_exit"
fi

# RNC-10: epics_in_flight must be non-empty and contain #446 (the parent epic),
# with #452 (the blocked open sibling) in the blocked list. auto_advanced and
# issue must both be null (no advance fired; next-up #451 is closed/done).
caseI_result=$(python3 -c "
import json
c = json.load(open('$I_FIXTURE/.arboretum/next-cache.json'))
ef = c.get('epics_in_flight', [])
nums = [e['number'] for e in ef]
aa = c.get('auto_advanced')
iss = c.get('issue')
if not ef:
    print('FAIL: epics_in_flight is empty — blocked-epic context was dropped (Fix B regression)')
elif 446 not in nums:
    print(f'FAIL: #446 not in epics_in_flight: {nums}')
elif aa is not None:
    print(f'FAIL: auto_advanced should be null when no advance, got {aa!r}')
elif iss is not None:
    print(f'FAIL: issue should be null (closed next-up), got {iss!r}')
else:
    # Verify #452 (blocked open sibling) appears as blocked under #446
    e446 = next(e for e in ef if e['number'] == 446)
    blocked_nums = [b['number'] for b in (e446.get('blocked') or [])]
    if 452 not in blocked_nums:
        print(f'FAIL: #452 not in blocked list of #446: {blocked_nums}')
    else:
        print('OK')
" 2>&1)
if [ "$caseI_result" = "OK" ]; then
  pass "RNC-10 (case I): blocked-epic context preserved in cache (epics_in_flight has #446 with blocked #452, auto_advanced null, issue null)"
else
  fail_case "RNC-10 (case I): blocked-epic-context assertion failed" "$caseI_result"
fi

# RNC-1 (case I): exact top-level key set
caseI_keys=$(python3 -c "
import json
print(sorted(json.load(open('$I_FIXTURE/.arboretum/next-cache.json')).keys()))
")
if [ "$caseI_keys" = "['auto_advanced', 'epics_in_flight', 'error', 'fetched_at', 'handoff', 'issue', 'no_gh_remote']" ]; then
  pass "RNC-1 (case I): blocked-epic cache has exactly the expected top-level keys"
else
  fail_case "RNC-1 (case I): unexpected top-level keys" "$caseI_keys"
fi

# Cleanup
rm -rf "$I_BIN" "$I_FIXTURE"
rm -f "$I_GRAPH_FILE"

# ── Summary ──────────────────────────────────────────────────────────

if [ "$fail" -eq 0 ]; then
  echo "All refresh-next-cache contract assertions passed."
  exit 0
else
  echo "Some refresh-next-cache contract assertions failed." >&2
  exit 1
fi
