#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-session-start-next.sh — Verify the session-handoff
# mechanism end-to-end (issue #155).
#
# Covers:
#   1. No git remote                  → silent skip
#   2. gh missing on PATH             → hard-fail block in hook output
#   3. gh stub returning a next-up    → cache populated, hook surfaces issue
#   4. Cache fresh (< 1h)             → hook does NOT call gh again
#   5. Cache stale (> 1h)             → hook kicks off background refresh
#   6. Empty-body issue               → annotated as failing readiness
#   7. gh stub returning empty list   → "no issue queued" rendering
#   8. Empty git history              → hook exits 0
#   9. ADO backend unavailable        → ADO diagnostic, not gh guidance
#
# Each case builds an isolated fixture under a tempdir and runs
# `.claude/hooks/session-start.sh` against it with a custom PATH that
# points at the appropriate stub.
#
# Usage: bash scripts/_smoke-test-session-start-next.sh
# Exit 0 if all cases pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"
REFRESH="$REPO_ROOT/scripts/refresh-next-cache.sh"

[ -f "$HOOK" ]    || { echo "FAIL: $HOOK not found" >&2; exit 1; }
[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; printf '%s\n' "$2" >&2; }
  exit 1
}

ok() { echo "PASS: $1"; }

# ── Helper: build a clean fixture project ────────────────────────────

new_fixture() {
  local name="$1"
  local fix="$ROOT_TMP/$name"
mkdir -p "$fix/docs/definitions" "$fix/docs/specs" "$fix/scripts/roadmap" "$fix/.claude/hooks" "$fix/.arboretum"
  echo "# fixture" > "$fix/docs/ARCHITECTURE.md"
  echo "# fixture" > "$fix/docs/REGISTER.md"
  echo "# fixture" > "$fix/contracts.yaml"
  cat > "$fix/.arboretum.yml" <<'EOF'
layer: 0
EOF
  # Copy the current hook + refresh script into the fixture so we
  # exercise the repository's current code at fixture-creation time.
  # Copy (not symlink) so a fixture remains stable if the working
  # tree is edited mid-test; rebuild the fixture to pick up changes.
  cp "$HOOK" "$fix/.claude/hooks/session-start.sh"
  mkdir -p "$fix/scripts/lib"; cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"
  cp "$REFRESH" "$fix/scripts/refresh-next-cache.sh"
  cp "$REPO_ROOT/scripts/roadmap/lib.sh" "$fix/scripts/roadmap/lib.sh"

  # Init git so the hook's git-author-count heuristic doesn't blow up
  # under set -e/pipefail. Disable signing for this fixture.
  git -C "$fix" init -q
  git -C "$fix" config user.email "fixture@example.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" -c commit.gpgsign=false -c gpg.program=true \
      commit -q --allow-empty -m "fixture seed" >/dev/null 2>&1 || true

  echo "$fix"
}

new_fixture_no_commit() {
  local name="$1"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/docs/definitions" "$fix/docs/specs" "$fix/scripts/roadmap" "$fix/.claude/hooks" "$fix/.arboretum"
  echo "# fixture" > "$fix/docs/ARCHITECTURE.md"
  echo "# fixture" > "$fix/docs/REGISTER.md"
  echo "# fixture" > "$fix/contracts.yaml"
  cat > "$fix/.arboretum.yml" <<'EOF'
layer: 0
EOF
  cp "$HOOK" "$fix/.claude/hooks/session-start.sh"
  mkdir -p "$fix/scripts/lib"; cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"
  cp "$REFRESH" "$fix/scripts/refresh-next-cache.sh"
  cp "$REPO_ROOT/scripts/roadmap/lib.sh" "$fix/scripts/roadmap/lib.sh"
  git -C "$fix" init -q
  echo "$fix"
}

# ── Helper: install a gh stub on PATH ────────────────────────────────
# Writes a stub `gh` script that switches on $GH_STUB_MODE at runtime.
# The default mode (when GH_STUB_MODE is unset) is the second arg to
# this helper, so callers can express intent both at install time and
# override per-run via the env var.
# Modes:
#   "issue"        — returns one open issue (#155, non-empty body)
#   "empty-issue"  — returns one open issue with empty body
#   "no-issues"    — returns []
#   "tripwire"     — fails loudly if called (for cache-hit case)

install_gh_stub() {
  local fix="$1"
  local default_mode="${2:-issue}"
  local bindir="$fix/.bin"
  mkdir -p "$bindir"
  # Note: the heredoc is unquoted-on-purpose for $default_mode only;
  # all other shell expansion in the stub is escaped with \$.
  cat > "$bindir/gh" <<STUB
#!/usr/bin/env bash
mode="\${GH_STUB_MODE:-$default_mode}"
log="\${GH_STUB_LOG:-/dev/null}"
echo "\$@" >> "\$log"

case "\$1 \$2" in
  "auth status")
    exit 0
    ;;
  "api repos/{owner}/{repo}")
    printf 'owner/repo\n'
    exit 0
    ;;
  "label create")
    exit 0
    ;;
  "issue list")
    case "\$mode" in
      "issue")
        cat <<'JSON'
[
  {
    "number": 155,
    "title": "Session handoff: capture next-session intent",
    "url": "https://github.com/example/repo/issues/155",
    "body": "## Context\n\nLong-running work spans multiple sessions. We want next-session intent surfaced at boot.\n\nMore details follow.",
    "labels": [{"name": "enhancement"}, {"name": "next-up"}],
    "updatedAt": "2026-04-28T12:00:00Z"
  }
]
JSON
        ;;
      "empty-issue")
        cat <<'JSON'
[
  {
    "number": 200,
    "title": "Bare issue with no body",
    "url": "https://github.com/example/repo/issues/200",
    "body": "",
    "labels": [{"name": "next-up"}],
    "updatedAt": "2026-04-28T12:00:00Z"
  }
]
JSON
        ;;
      "no-issues")
        echo "[]"
        ;;
      "tripwire")
        echo "TRIPWIRE: gh was called when cache should have been used" >&2
        exit 99
        ;;
    esac
    exit 0
    ;;
  *)
    echo "stub: unhandled gh args: \$*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$bindir/gh"
  echo "$bindir"
}

run_hook() {
  # $1 = fixture, rest = extra env vars to set
  local fix="$1"; shift
  CLAUDE_PROJECT_DIR="$fix" \
    env "$@" bash "$fix/.claude/hooks/session-start.sh" 2>&1
}

# ── Case 1: no git remote ────────────────────────────────────────────

fix=$(new_fixture case1)
out=$(run_hook "$fix" "PATH=$PATH")
if echo "$out" | grep -q '^\[Next-up\]'; then
  fail "case 1 — no git remote should produce no [Next-up] block" "$out"
fi
ok "case 1 — silent skip when no git remote"

# ── Case 2: gh missing on PATH ───────────────────────────────────────

fix=$(new_fixture case2)
git -C "$fix" remote add origin "https://github.com/example/repo.git"

# Build a truly isolated PATH for this case: symlink only the tools
# the hook actually needs (bash, git, awk, sed, grep, find, date,
# stat, mktemp, cat, head, cut, tr, wc, sort, sleep, basename,
# dirname, env, mv, rm, mkdir, touch, printf, true, false, cp,
# python3) and crucially OMIT `gh`. Without this, a real `gh` on
# the developer's PATH (common in CI/dev machines under
# /usr/local/bin or /usr/bin) would defeat this test.
case2_bin="$fix/.bin-isolated"
mkdir -p "$case2_bin"
for tool in bash sh git awk sed grep find date stat mktemp cat head \
            cut tr wc sort sleep basename dirname env mv rm mkdir \
            touch printf true false cp python3 chmod ls echo tail \
            test [ stty tty xargs uname; do
  resolved=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    ln -sf "$resolved" "$case2_bin/$tool"
  fi
done
# Sanity: confirm `gh` is NOT reachable on this PATH.
if PATH="$case2_bin" command -v gh >/dev/null 2>&1; then
  fail "case 2 setup — isolated PATH still resolves gh; test cannot run deterministically"
fi

out=$(run_hook "$fix" "PATH=$case2_bin")
echo "$out" | grep -q 'gh CLI not available' \
  || fail "case 2 — expected hard-fail block when gh is missing" "$out"
echo "$out" | grep -q 'gh auth login' \
  || fail "case 2 — expected install/auth instructions" "$out"
ok "case 2 — hard-fail block when gh is missing"

# ── Case 3: gh stub returns a next-up issue ──────────────────────────

fix=$(new_fixture case3)
git -C "$fix" remote add origin "https://github.com/example/repo.git"
bindir=$(install_gh_stub "$fix" "issue")
out=$(run_hook "$fix" "PATH=$bindir:$PATH" "GH_STUB_MODE=issue")

# #763: the model-facing banner renders only the bare issue number — no
# author-controlled issue title, body lines, or URL reach additionalContext.
echo "$out" | grep -qE '^\[Next-up\] #155$' \
  || fail "case 3 — expected bare '[Next-up] #155' line (no title; #763)" "$out"
echo "$out" | grep -q 'Session handoff: capture' \
  && fail "case 3 — issue TITLE must NOT render in the model-facing banner (#763)" "$out"
echo "$out" | grep -q 'Long-running work spans multiple sessions' \
  && fail "case 3 — issue BODY must NOT render in the banner (#763)" "$out"
echo "$out" | grep -q 'github.com/example/repo/issues/155' \
  && fail "case 3 — issue URL must NOT render in the banner (#763)" "$out"

# Cache should now exist
[ -f "$fix/.arboretum/next-cache.json" ] \
  || fail "case 3 — cache file not written"
grep -q '"number": 155' "$fix/.arboretum/next-cache.json" \
  || fail "case 3 — cache JSON missing issue number"
ok "case 3 — gh stub issue surfaces as bare #155 (no title/body/url); cache populated"

# ── Case 4: cache fresh (< 1h), gh tripwire ──────────────────────────

# Reuse case3's fixture — its cache is now fresh (just written).
# Replace the stub with a tripwire that fails if called.
trip_bindir=$(install_gh_stub "$fix" "tripwire")

# Expect the hook to read the cache without invoking gh.
out=$(run_hook "$fix" "PATH=$trip_bindir:$PATH" "GH_STUB_MODE=tripwire")
# If tripwire fired, output would contain "TRIPWIRE"
echo "$out" | grep -q 'TRIPWIRE' \
  && fail "case 4 — cache was fresh but gh was invoked anyway" "$out"
echo "$out" | grep -qE '^\[Next-up\] #155' \
  || fail "case 4 — expected cached banner line on cache hit" "$out"
ok "case 4 — fresh cache prevents gh re-invocation"

# ── Case 5: cache stale → background refresh kicks in ────────────────

# Make cache mtime two hours old (well past TTL = 1h)
touch -d "2 hours ago" "$fix/.arboretum/next-cache.json" 2>/dev/null \
  || touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null \
                || date -d "2 hours ago" +%Y%m%d%H%M.%S)" \
       "$fix/.arboretum/next-cache.json"

# Replace tripwire with a fresh-issue stub. The hook should emit the
# previously-cached state synchronously and trigger a background
# refresh; we verify the refresh ran by waiting briefly and checking
# the cache mtime advanced.
ok_bindir=$(install_gh_stub "$fix" "issue")
old_mtime=$(stat -c %Y "$fix/.arboretum/next-cache.json" 2>/dev/null \
  || stat -f %m "$fix/.arboretum/next-cache.json")
out=$(run_hook "$fix" "PATH=$ok_bindir:$PATH" "GH_STUB_MODE=issue")
echo "$out" | grep -qE '^\[Next-up\] #155' \
  || fail "case 5 — expected stale-cache banner before background refresh"  "$out"

# Wait for the background refresh to land (cap at 5s)
for _ in 1 2 3 4 5; do
  new_mtime=$(stat -c %Y "$fix/.arboretum/next-cache.json" 2>/dev/null \
    || stat -f %m "$fix/.arboretum/next-cache.json")
  [ "$new_mtime" -gt "$old_mtime" ] && break
  sleep 1
done
[ "$new_mtime" -gt "$old_mtime" ] \
  || fail "case 5 — background refresh did not update cache mtime within 5s"
ok "case 5 — stale cache triggers background refresh"

# ── Case 6: empty-body issue ─────────────────────────────────────────

fix=$(new_fixture case6)
git -C "$fix" remote add origin "https://github.com/example/repo.git"
bindir=$(install_gh_stub "$fix" "empty-issue")
out=$(run_hook "$fix" "PATH=$bindir:$PATH" "GH_STUB_MODE=empty-issue")
echo "$out" | grep -qE '^\[Next-up\] #200$' \
  || fail "case 6 — expected bare '[Next-up] #200' line" "$out"
# #763: the body is no longer surfaced, so the body-empty annotation is gone.
echo "$out" | grep -q 'body empty' \
  && fail "case 6 — body-empty annotation must NOT render (#763, body no longer surfaced)" "$out"
ok "case 6 — empty-body issue renders bare #200 (no body annotation; #763)"

# ── Case 7: gh stub returns empty list ───────────────────────────────

fix=$(new_fixture case7)
git -C "$fix" remote add origin "https://github.com/example/repo.git"
bindir=$(install_gh_stub "$fix" "no-issues")
out=$(run_hook "$fix" "PATH=$bindir:$PATH" "GH_STUB_MODE=no-issues")
echo "$out" | grep -q 'no issue queued' \
  || fail "case 7 — expected '(no issue queued — run /handoff to set one)'" "$out"
ok "case 7 — empty next-up renders as 'no issue queued'"

# ── Case 8: empty git history must not crash the hook ────────────────

fix=$(new_fixture_no_commit case8)
set +e
out=$(run_hook "$fix" "PATH=$PATH")
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "case 8 — empty git history should not make SessionStart exit nonzero" "rc=$rc output=$out"
ok "case 8 — empty git history exits 0"

# ── Case 9: ADO backend unavailable renders ADO guidance ─────────────

fix=$(new_fixture case9)
rm -f "$fix/.arboretum.yml"
cat > "$fix/roadmap.config.yaml" <<'YAML'
backend: azure-devops
azure_devops:
  organization: VCH-DataAnalytics
  project: Advanced_Data_Analytics
YAML
git -C "$fix" remote add origin "https://dev.azure.com/VCH-DataAnalytics/Advanced_Data_Analytics/_git/cedar"

case9_bin="$fix/.bin-isolated"
mkdir -p "$case9_bin"
for tool in bash sh git awk sed grep find date stat mktemp cat head \
            cut tr wc sort sleep basename dirname env mv rm mkdir \
            touch printf true false cp python3 chmod ls echo tail \
            test [ stty tty xargs uname jq; do
  resolved=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    ln -sf "$resolved" "$case9_bin/$tool"
  fi
done

out=$(run_hook "$fix" "PATH=$case9_bin")
echo "$out" | grep -q 'Azure DevOps backend unavailable' \
  || fail "case 9 — expected Azure DevOps unavailable diagnostic" "$out"
if echo "$out" | grep -q 'gh CLI not available'; then
  fail "case 9 — ADO backend failure must not render gh CLI guidance" "$out"
fi
ok "case 9 — ADO backend failure renders ADO diagnostic"

# ── Case 10: handoff note renders; issue title never does (#763) ─────
#
# Seed a fresh next-cache.json directly (cache-hit path, no gh) carrying a
# trusted-author handoff and the post-#763 issue shape ({number} only, no
# title). Assert the bare [Next-up] #300 line + the handoff note both render —
# the narrative-delta feature is preserved — and that nothing title-shaped
# leaks into the model-facing banner.

fix=$(new_fixture case10)
git -C "$fix" remote add origin "https://github.com/example/repo.git"
cat > "$fix/.arboretum/next-cache.json" <<'JSON'
{
  "fetched_at": "2026-06-12T00:00:00Z",
  "issue": { "number": 300 },
  "handoff": { "posted_at": "2026-06-12T00:00:00Z", "branch": "feat/x", "next_action": "wire the seam", "body": "watch the contract coupling" },
  "no_gh_remote": false,
  "error": null
}
JSON
out=$(run_hook "$fix" "PATH=$PATH")
echo "$out" | grep -qE '^\[Next-up\] #300$' \
  || fail "case 10 — expected bare '[Next-up] #300'" "$out"
echo "$out" | grep -q '→ Next action: wire the seam' \
  || fail "case 10 — trusted-author handoff next_action must render (narrative delta preserved)" "$out"
echo "$out" | grep -q 'watch the contract coupling' \
  || fail "case 10 — handoff prose must render" "$out"
ok "case 10 — handoff note renders; bare #300, no issue title in the banner"

# ── Done ─────────────────────────────────────────────────────────────

echo
echo "All session-handoff smoke-test cases passed."
exit 0
