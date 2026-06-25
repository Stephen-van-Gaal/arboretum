#!/usr/bin/env bash
# owner: session-start-cycle-state
# scope: plugin-only
# (Owns under the existing session-start-cycle-state spec — this extends the
#  session-start cycle. A standalone governed spec for this feature, if
#  warranted, is born at /consolidate per v2; the owner must resolve to an
#  EXISTING spec now or _smoke-test-script-owners.sh fails. Copilot #376.)
# refresh-workspace-cache.sh — Refresh .arboretum/workspace-cache.json.
#
# Gathers the git WORKSPACE dimension for the SessionStart banner's
# [Workspace] block: current branch, dirty state, local-vs-remote drift
# (main vs main@{upstream}; current branch vs @{upstream}), worktrees, and
# (GitHub only) the open PR for the current branch.
#
# Local facts are cheap (no network) and recomputed every boot. The
# `git fetch` is SYNCHRONOUS with a 5s timeout so staleness is accurate
# THIS session (goal #1) without ever hanging boot.
#
# Cache shape — see docs/contracts/refresh-workspace-cache.contract.md.
# All author-controlled strings (branch names, worktree paths, PR title/
# url) are stripped of ASCII control chars before serialization.
#
# Usage: bash scripts/refresh-workspace-cache.sh [project-dir]
# Exit codes: 0 — cache written (always, even on degraded paths).

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/scrub-control-chars.sh"

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/workspace-cache.json"
FETCH_TIMEOUT="${ARBO_WORKSPACE_FETCH_TIMEOUT:-5}"

mkdir -p "$CACHE_DIR"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

write_cache() {
  # Atomic write via per-process mktemp + mv (safe under concurrent refresh).
  local tmp
  tmp=$(mktemp "$CACHE_DIR/workspace-cache.json.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

g() { git -C "$PROJECT_DIR" "$@"; }

# Not a git repo → minimal cache, banner stays silent.
if ! g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "fetch_ok": false,
  "provider": "unknown",
  "current_branch": null,
  "dirty": false, "dirty_count": 0,
  "main": null, "current_upstream": null,
  "worktrees": [], "local_branches": [], "open_pr": null,
  "error": "not-a-git-repo"
}' "$(now_iso)")"
  exit 0
fi
# ── Local facts (cheap, no network) ──────────────────────────────────
current_branch=$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)  # empty = detached
dirty_count=$(g status --porcelain 2>/dev/null | grep -c . || true)
worktrees_raw=$(g worktree list --porcelain 2>/dev/null || true)
# Local branch names — used by the renderer to verify a /handoff-recorded
# branch still exists before recommending "resume" (Codex #376 review).
branches_raw=$(g for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)

# Primary remote (origin-preferred, else first) — used for the main@{upstream}
# fallback below and for provider/PR detection in Task 3.
if g remote 2>/dev/null | grep -qx origin; then
  remote=origin
else
  remote=$(g remote 2>/dev/null | head -n1 || true)
fi

# main vs ITS configured upstream — not hardcoded origin/main. A fork may
# track main on a different remote (e.g. `upstream/main`). When main has no
# explicit @{upstream}, fall back to the PRIMARY remote's main (origin/main
# when origin exists, else <remote>/main) — never assume origin (Codex #376).
main_up=$(g rev-parse --abbrev-ref --symbolic-full-name 'main@{upstream}' 2>/dev/null || true)
if [ -z "$main_up" ] && [ -n "$remote" ] \
   && g rev-parse --verify --quiet "refs/remotes/$remote/main" >/dev/null 2>&1; then
  main_up="$remote/main"
fi
main_behind=""; main_ahead=""
if [ -n "$main_up" ] && g rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
  read -r main_behind main_ahead < <(g rev-list --left-right --count "${main_up}...main" 2>/dev/null || echo "")
fi

# current branch vs its @{upstream} (which may be on a DIFFERENT remote than
# main's upstream — both are fetched from their own remote below).
up_name=""; up_behind=""; up_ahead=""
if [ -n "$current_branch" ]; then
  up_name=$(g rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [ -n "$up_name" ]; then
    read -r up_behind up_ahead < <(g rev-list --left-right --count "${up_name}...HEAD" 2>/dev/null || echo "")
  fi
fi

build_cache() {
  # $1 = fetch_ok ("true"/"false"); $2 = provider; $3 = open_pr JSON ("null" or object)
  # No-python3 fallback (RWC-1: ALWAYS write a parseable cache). Without
  # this guard, command substitution would yield "" and write_cache would
  # persist an empty file, silently killing the [Workspace] banner. Mirrors
  # refresh-next-cache.sh's no-python3 path (Codex #376 review).
  if ! command -v python3 >/dev/null 2>&1; then
    printf '{
  "fetched_at": "%s", "fetch_ok": %s, "provider": "%s",
  "current_branch": null, "dirty": false, "dirty_count": 0,
  "main": null, "current_upstream": null, "worktrees": [],
  "local_branches": [], "open_pr": null, "error": "python3-unavailable"
}' "$(now_iso)" "$1" "$2"
    return
  fi
  PROJECT_DIR="$PROJECT_DIR" FETCH_OK="$1" PROVIDER="$2" OPEN_PR="$3" \
  CURRENT_BRANCH="$current_branch" DIRTY_COUNT="$dirty_count" \
  MAIN_BEHIND="$main_behind" MAIN_AHEAD="$main_ahead" MAIN_FRESH="${main_fresh:-false}" \
  UP_NAME="$up_name" UP_BEHIND="$up_behind" UP_AHEAD="$up_ahead" \
  WORKTREES_RAW="$worktrees_raw" BRANCHES_RAW="$branches_raw" FETCHED_AT="$(now_iso)" \
  python3 - <<'PY'
import json, os, re
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s): return _CTRL.sub("", s) if isinstance(s, str) else s
def intn(v):
    v = (v or "").strip()
    return int(v) if v.isdigit() else None

def parse_worktrees(raw):
    # No `dirty` field: `git worktree list --porcelain` doesn't report
    # dirtiness, and computing it would need a `git status` per worktree on
    # every boot for data the v1 renderer doesn't consume. Dropped (YAGNI)
    # rather than promised-but-always-null (Codex #376 review).
    out, cur = [], {}
    for line in raw.splitlines():
        if line.startswith("worktree "):
            if cur: out.append(cur)
            cur = {"path": scrub(line[len("worktree "):]), "branch": None}
        elif line.startswith("branch "):
            cur["branch"] = scrub(line[len("branch "):].replace("refs/heads/", ""))
        elif line == "detached":
            cur["branch"] = None
    if cur: out.append(cur)
    return out

cb = scrub(os.environ["CURRENT_BRANCH"]) or None
mb, ma = intn(os.environ["MAIN_BEHIND"]), intn(os.environ["MAIN_AHEAD"])
main = {"behind": mb, "ahead": ma, "fresh": os.environ.get("MAIN_FRESH") == "true"} if mb is not None and ma is not None else None
upn = scrub(os.environ["UP_NAME"]) or None
ub, ua = intn(os.environ["UP_BEHIND"]), intn(os.environ["UP_AHEAD"])
upstream = {"name": upn, "behind": ub, "ahead": ua} if upn else None
dc = intn(os.environ["DIRTY_COUNT"]) or 0
open_pr = json.loads(os.environ["OPEN_PR"])
if isinstance(open_pr, dict):
    for k in ("title", "url", "state"):
        if k in open_pr: open_pr[k] = scrub(str(open_pr[k]))

cache = {
    "fetched_at": os.environ["FETCHED_AT"],
    "fetch_ok": os.environ["FETCH_OK"] == "true",
    "provider": os.environ["PROVIDER"],
    "current_branch": cb,
    "dirty": dc > 0, "dirty_count": dc,
    "main": main, "current_upstream": upstream,
    "worktrees": parse_worktrees(os.environ["WORKTREES_RAW"]),
    "local_branches": [scrub(l) for l in os.environ.get("BRANCHES_RAW", "").splitlines() if l.strip()],
    "open_pr": open_pr if isinstance(open_pr, dict) else None,
    "error": None,
}
print(json.dumps(cache, indent=2))
PY
}

# ── Synchronous fetch with timeout (goal #1: accurate-this-session) ──
# Fetch EACH tracked ref from the remote it actually lives on (main's
# upstream and the current branch's upstream may be on different remotes),
# using explicit destination refspecs so the remote-tracking refs the rail
# compares are genuinely updated — a bare `git fetch <r> <branch>` writes
# only FETCH_HEAD and leaves refs/remotes/<r>/<branch> stale (Copilot+Codex
# #376). fetch_ok = every attempted fetch reached its remote.
fetch_ok=true
fetched_any=false

# Bounded fetch of one upstream ref. $1 = upstream like `origin/main` or
# `upstream/feat/x`. Returns non-zero if the fetch failed or timed out.
fetch_upstream() {
  local up="$1" r="" b cand; [ -z "$up" ] && return 0
  # Remote names may contain slashes (`git remote add foo/bar ...`), so a
  # naive `${up%%/*}` split mis-parses an upstream like `foo/bar/main` into
  # remote `foo` + branch `bar/main` and the fetch fails (Codex #378). Match
  # `up` against the actual configured remotes, longest-prefix-wins.
  while IFS= read -r cand; do
    case "$up" in "$cand"/*) [ "${#cand}" -gt "${#r}" ] && r="$cand" ;; esac
  done < <(git -C "$PROJECT_DIR" remote 2>/dev/null)
  [ -z "$r" ] && r="${up%%/*}"   # fallback: no configured remote prefixes up
  b="${up#"$r"/}"
  fetched_any=true
  local cmd=(git -C "$PROJECT_DIR" fetch --quiet "$r" "+refs/heads/$b:refs/remotes/$r/$b")
  if command -v timeout >/dev/null 2>&1; then
    timeout "$FETCH_TIMEOUT" "${cmd[@]}" >/dev/null 2>&1 || return 1
  else
    # No GNU timeout (default macOS) → background + sleep-kill bound.
    "${cmd[@]}" >/dev/null 2>&1 & local fpid=$!
    ( sleep "$FETCH_TIMEOUT"; kill "$fpid" 2>/dev/null ) >/dev/null 2>&1 & local wpid=$!
    if wait "$fpid" 2>/dev/null; then kill "$wpid" 2>/dev/null || true; else kill "$wpid" 2>/dev/null; return 1; fi
  fi
  return 0
}

# Fetch main's upstream and the current branch's upstream from their own
# remotes, tracking freshness PER comparison — a deleted/missing feature-branch
# upstream must NOT poison main's freshness (Codex #376). main_fresh gates the
# "(current ✓)" claim; the current-branch fetch only affects fetch_ok.
main_fresh=false
if [ -n "$main_up" ]; then
  if fetch_upstream "$main_up"; then main_fresh=true; else fetch_ok=false; fi
fi
# Current-branch upstream may live on a different remote than main's — fetch it
# too (unless it IS main's upstream, already fetched). Failure only lowers
# fetch_ok; it must NOT touch main_fresh (per-comparison freshness).
if [ -n "$up_name" ] && [ "$up_name" != "$main_up" ]; then
  fetch_upstream "$up_name" || fetch_ok=false
fi
$fetched_any || fetch_ok=false   # nothing tracked to fetch → staleness unknown

# Recompute drift AFTER fetch so the rail reflects freshly-updated refs.
if [ -n "$main_up" ] && g rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
  read -r main_behind main_ahead < <(g rev-list --left-right --count "${main_up}...main" 2>/dev/null || echo "")
fi
if [ -n "$up_name" ]; then
  read -r up_behind up_ahead < <(g rev-list --left-right --count "${up_name}...HEAD" 2>/dev/null || echo "")
fi

# ── Provider detection (from origin URL) ─────────────────────────────
# Provider/PR use the origin-preferred remote (distinct from the per-upstream
# fetch above): dev.azure.com / visualstudio.com / ssh.dev.azure.com →
# azure-devops; else github (github.com, GHE, cloud-proxy — same looseness as
# refresh-next-cache.sh). Future: extract into shared backend helper.
if g remote 2>/dev/null | grep -qx origin; then
  remote=origin
else
  remote=$(g remote 2>/dev/null | head -n1 || true)
fi
provider=github
origin_url=$(g remote get-url "${remote:-origin}" 2>/dev/null || true)
case "$origin_url" in
  *dev.azure.com*|*visualstudio.com*) provider=azure-devops ;;
  "") provider=unknown ;;
esac

# ── Mode-E open-PR lookup (provider-aware, graceful) ─────────────────
open_pr=null
if [ -n "$current_branch" ] && [ "$provider" = "github" ] && command -v gh >/dev/null 2>&1; then
  # `gh pr list` has no built-in timeout and this producer runs synchronously
  # on every boot, so it MUST be bounded (RWC-9). When GNU `timeout` is
  # available, wrap it; when it is NOT (default macOS), SKIP the lookup
  # entirely rather than risk an unbounded hang on a stalled credential
  # helper — mode E degrades to open_pr:null; modes A–D are unaffected
  # (Codex+Copilot #376). The background-kill trick used for fetch can't
  # capture stdout reliably, so skip-when-unbounded is the honest choice.
  if command -v timeout >/dev/null 2>&1; then
    pr_json=$(cd "$PROJECT_DIR" && timeout "$FETCH_TIMEOUT" gh pr list --head "$current_branch" \
                --state open --json number,url,title,state --jq '.[0] // empty' 2>/dev/null || true)
    [ -n "$pr_json" ] && open_pr="$pr_json"
  fi
fi
# Azure DevOps: deliberate no-op for v1 (open_pr stays null). Consistent
# with roadmap-backend-abstraction.spec.md (Azure returns empty PR list)
# and the /land-on-ADO ceremonial stance. A future AzureDevOpsBackend
# replaces this branch with a real `az repos pr list` call.

write_cache "$(build_cache "$fetch_ok" "$provider" "$open_pr")"
exit 0
