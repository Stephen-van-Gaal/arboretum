#!/usr/bin/env bash
# owner: epic-aware-orientation
# _smoke-test-epic-aware-banner.sh — Integration smoke test for the
# [Epics in flight] boot-banner section (Task 8, issue #562).
#
# Exercises the FULL chain: gh stub → refresh-next-cache.sh (live epic-walk
# → roadmap_github_epic_graph → gh api graphql via stub) → next-cache.json
# → session-start.sh render → asserts banner contains [Epics in flight].
#
# Uses the faithful #295 graph fixture from:
#   tests/fixtures/epic-walk/github-graphql-295.json
#
# The gh stub returns the raw GraphQL fixture for `gh api graphql` and a
# next-up issue list for #305. No network calls are made.
#
# Auto-discovered by ci-checks.sh's === Smoke tests === loop.
#
# See: docs/contracts/epic-walk.contract.md (EW-1..EW-7)

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REFRESH="$SCRIPT_DIR/refresh-next-cache.sh"
HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"
GRAPHQL_FIXTURE="$REPO_ROOT/tests/fixtures/epic-walk/github-graphql-295.json"

[ -f "$REFRESH" ]          || { echo "FAIL: $REFRESH not found" >&2; exit 1; }
[ -f "$HOOK" ]             || { echo "FAIL: $HOOK not found" >&2; exit 1; }
[ -f "$GRAPHQL_FIXTURE" ]  || { echo "FAIL: $GRAPHQL_FIXTURE not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
GH_STUB_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$GH_STUB_DIR"' EXIT

fail=0
pass()      { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; printf '%s\n' "$2" >&2; }
  fail=1
}

# ── Build the gh stub ─────────────────────────────────────────────────
#
# Handles the same command surface as the contract test stub:
#   `gh auth status`              → exit 0
#   `gh api repos/{owner}/{repo}` → exit 0 (probe)
#   `gh repo view --json owner -q .owner.login` → "Stephen-van-Gaal"
#   `gh repo view --json name -q .name`         → "arboretum-dev"
#   `gh api graphql ...`          → contents of $GH_STUB_GRAPHQL env var
#   `gh issue list ...`           → contents of $GH_STUB_ISSUES env var
#   `gh issue view ...`           → empty comments JSON
#
# GH_STUB_GRAPHQL is set by the test to the raw GraphQL fixture content
# before invoking refresh-next-cache.sh, so roadmap_github_epic_graph
# receives it and parses the #295 graph.

cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
default_comments='{"comments":[]}'
default_graphql='{"data":{"repository":{"issue":null}}}'
case "$1" in
  auth)
    case "$2" in
      status) exit 0 ;;
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
            .owner.login) printf 'Stephen-van-Gaal\n'; exit 0 ;;
            .name) printf 'arboretum-dev\n'; exit 0 ;;
          esac
        done
        printf 'Stephen-van-Gaal/arboretum-dev\n'
        exit 0
        ;;
    esac
    ;;
  api)
    case "$2" in
      repos/*)
        # Live-access probe: gh api repos/{owner}/{repo}
        printf 'Stephen-van-Gaal/arboretum-dev\n'
        exit 0
        ;;
      graphql)
        # roadmap_github_epic_graph — return injected raw GraphQL response.
        printf '%s\n' "${GH_STUB_GRAPHQL:-$default_graphql}"
        exit 0
        ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        printf '%s' "${GH_STUB_ISSUES:-[]}"
        exit 0
        ;;
      view)
        # Comment fetch for the next-up issue — return empty comments.
        printf '%s' "$default_comments"
        exit 0
        ;;
      edit)
        exit 0
        ;;
    esac
    ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$GH_STUB_DIR/gh"

# ── Build the fixture project ─────────────────────────────────────────
#
# Needs git init with a remote so refresh-next-cache.sh does not fire its
# `no_gh_remote: true` short-circuit. The remote URL is synthetic.

( cd "$FIXTURE" && \
  git init -q && \
  git remote add origin "https://github.com/Stephen-van-Gaal/arboretum-dev.git" )
touch "$FIXTURE/CLAUDE.md"
mkdir -p "$FIXTURE/scripts"
touch "$FIXTURE/scripts/refresh-next-cache.sh"
# Pin LAYER=2 so session-start skips the Layer<2 suggestion block (which
# triggers set -e under an empty git history and exits before [Next-up]).
echo "layer: 2" > "$FIXTURE/.arboretum.yml"

# ── Load the raw GraphQL fixture into the env var ────────────────────
#
# GH_STUB_GRAPHQL is consumed by the gh stub's `api graphql` branch.
# roadmap_github_epic_graph writes this to a temp file and pipes it through
# its python core, which produces the graph JSON for epic-walk.sh.

export GH_STUB_GRAPHQL
GH_STUB_GRAPHQL=$(cat "$GRAPHQL_FIXTURE")

# ── Set the next-up issue list ───────────────────────────────────────
#
# refresh-next-cache.sh calls `gh issue list --label next-up ...` to find
# the current next-up issue. Return #305 with the next-up label.

export GH_STUB_ISSUES='[{"number":305,"title":"WS7: Intake pipeline","url":"https://github.com/Stephen-van-Gaal/arboretum-dev/issues/305","body":"<!-- pipeline-state:current-stage --> **Current stage:** /build\n\nIntake pipeline implementation.","labels":[{"name":"next-up"}],"updatedAt":"2026-06-05T00:00:00Z"}]'

# ── Run the full refresh ──────────────────────────────────────────────
#
# refresh-next-cache.sh calls epic-walk.sh in live mode, which calls
# roadmap_epic_graph → roadmap_github_epic_graph → gh api graphql (stub).
# The stub returns GH_STUB_GRAPHQL, which is the #295 faithful fixture.

PATH="$GH_STUB_DIR:$PATH" bash "$REFRESH" "$FIXTURE" >/dev/null 2>&1
refresh_exit=$?

if [ "$refresh_exit" -eq 0 ]; then
  pass "INT-1: refresh-next-cache.sh exits 0"
else
  fail_case "INT-1: refresh-next-cache.sh exited $refresh_exit (expected 0)"
fi

# ── Verify cache contains epics_in_flight before rendering ───────────

CACHE_FILE="$FIXTURE/.arboretum/next-cache.json"
if [ -f "$CACHE_FILE" ]; then
  pass "INT-2: next-cache.json was written"
else
  fail_case "INT-2: next-cache.json was not written after refresh"
fi

cache_check=$(python3 -c "
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    ef = c.get('epics_in_flight')
    if not isinstance(ef, list) or len(ef) == 0:
        print('FAIL: epics_in_flight empty or missing: ' + repr(ef))
    elif not any(e['number'] == 295 for e in ef):
        print('FAIL: #295 not in epics_in_flight: ' + str([e['number'] for e in ef]))
    else:
        active = ef[0].get('active', [])
        if not any(a['number'] == 305 for a in active):
            print('FAIL: #305 not in active: ' + repr(active))
        else:
            print('OK')
except Exception as ex:
    print('FAIL: ' + str(ex))
" "$CACHE_FILE" 2>&1)
if [ "$cache_check" = "OK" ]; then
  pass "INT-3: cache contains epics_in_flight with #295 and active #305"
else
  fail_case "INT-3: cache epics_in_flight assertion failed" "$cache_check"
fi

# ── Run session-start.sh and capture the rendered banner ─────────────
#
# The hook reads $FIXTURE/.arboretum/next-cache.json (written above) and
# renders the [Epics in flight] section via its python3 block. We set
# CLAUDE_PROJECT_DIR so the hook finds the fixture. We also need to
# ensure the hook does not attempt a background refresh of workspace-cache
# (no refresh-workspace-cache.sh exists in the fixture — the hook
# guards with `[ -f "$WORKSPACE_REFRESH" ]` so this is safe).

out=$(CLAUDE_PROJECT_DIR="$FIXTURE" PATH="$GH_STUB_DIR:$PATH" bash "$HOOK" 2>&1 || true)

# ── Assert banner contents ────────────────────────────────────────────

if printf '%s' "$out" | grep -qF '[Epics in flight]'; then
  pass "INT-4: banner contains [Epics in flight] section header"
else
  fail_case "INT-4: [Epics in flight] section header missing from banner" "$out"
fi

if printf '%s' "$out" | grep -qF '[#295]'; then
  pass "INT-5: banner contains [#295] epic header"
else
  fail_case "INT-5: [#295] epic header missing from banner" "$out"
fi

# #305 is active (stage=/build ≥ /design threshold) so it renders with ▸ prefix.
if printf '%s' "$out" | grep -qF '▸ #305'; then
  pass "INT-6: banner renders #305 as active child (▸ #305)"
else
  fail_case "INT-6: ▸ #305 (active child marker) missing from banner" "$out"
fi

if printf '%s' "$out" | grep -qF '▸ active · • next · ⊘ blocked'; then
  pass "INT-7: banner contains legend line"
else
  fail_case "INT-7: legend line '▸ active · • next · ⊘ blocked' missing from banner" "$out"
fi

# auto_advanced is null (next-up #305 is OPEN, no advance should fire).
# The legend line contains "⤴ auto-advanced" as a label, so match the
# full auto-advance notification prefix "⤴ auto-advanced next-up:" to
# distinguish it from the legend entry.
if printf '%s' "$out" | grep -qF '⤴ auto-advanced next-up:'; then
  fail_case "INT-8: unexpected ⤴ auto-advanced next-up: line in banner (next-up #305 is open; no advance expected)" "$out"
else
  pass "INT-8: no spurious ⤴ auto-advanced notification (correct: next-up is open)"
fi

# ── Summary ──────────────────────────────────────────────────────────

if [ "$fail" -eq 0 ]; then
  echo "All epic-aware banner integration assertions passed."
  exit 0
else
  echo "Some epic-aware banner integration assertions failed." >&2
  exit 1
fi
