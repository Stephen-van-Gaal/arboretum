#!/usr/bin/env bash
# owner: session-start-cycle-state
# SessionStart hook: produce a compact project state summary for Claude's context.
# Reads REGISTER.md, contracts.yaml, and definition files to surface:
# - Which specs exist and their statuses
# - Any stale version pins (contracts.yaml vs definition files)
# - What's next in the dependency resolution order
#
# Output goes to Claude's context as additionalContext.
# Must be fast — runs on every session start.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
CONFIG="$PROJECT_DIR/.arboretum.yml"

# Detect current layer (default: 0)
LAYER=$(sed -n 's/^layer:[[:space:]]*\([0-9]\).*/\1/p' "$CONFIG" 2>/dev/null || true)
LAYER="${LAYER:-0}"

output=""

# ── Dogfood banner ───────────────────────────────────────────────────
# Gated by `dogfood: true` in .arboretum.yml. This hook syncs to the
# public arboretum plugin, but .arboretum.yml is sync-excluded — so the
# flag (and this line) only fire in arboretum-dev, not in downstream
# projects that install arboretum.
DOGFOOD=$(sed -n 's/^dogfood:[[:space:]]*\([a-zA-Z]*\).*/\1/p' "$CONFIG" 2>/dev/null || true)
if [ "$DOGFOOD" = "true" ]; then
  output+="[Dogfood] arboretum-dev runs its own in-development tooling — validate changes here before they sync to public."
fi

# ── Check if governed documents exist ────────────────────────────────

missing=()
[ ! -f "$PROJECT_DIR/docs/ARCHITECTURE.md" ] && missing+=("ARCHITECTURE.md")
[ ! -f "$REGISTER" ] && missing+=("REGISTER.md")
[ ! -f "$CONTRACTS" ] && missing+=("contracts.yaml")
[ ! -d "$DEFS_DIR" ] && missing+=("docs/definitions/")

if [ ${#missing[@]} -gt 0 ]; then
  [ -n "$output" ] && output+=$'\n'
  output+="[Spec Workflow] Missing governed documents: ${missing[*]}."
  output+=$'\n'"  → Why: The document chain must exist top-down before specs can be implemented."
  output+=$'\n'"    Create them in order: ARCHITECTURE.md → definitions/ → specs → REGISTER.md → contracts.yaml. See workflows/README.md."
fi

# ── Session handoff (next-up GitHub issue) ───────────────────────────
# Surface the issue tagged with the `next-up` label on GitHub. The
# cache at .arboretum/next-cache.json is refreshed by
# scripts/refresh-next-cache.sh (synchronously on first session,
# in the background when stale). 1-hour TTL.
#
# Deliberately not plugin-aware — the cache is a project artefact, never
# plugin-shipped. Rooting at $PROJECT_DIR is correct here (#145).
#
# See issue #155 and docs/superpowers/specs/2026-04-28-session-handoff-design.md.

NEXT_CACHE="$PROJECT_DIR/.arboretum/next-cache.json"
NEXT_REFRESH="$PROJECT_DIR/scripts/refresh-next-cache.sh"
NEXT_TTL_SECONDS=3600

# Per-session markers (design §4.7–§4.8): handoff-done / handoff-nudged
# are scoped to one session — clear them at every boot. Surface and
# clear the SessionEnd safety-net flag if the previous session left one.
HANDOFF_MARK_DIR="$PROJECT_DIR/.arboretum"
rm -f "$HANDOFF_MARK_DIR/handoff-done" "$HANDOFF_MARK_DIR/handoff-nudged"
HANDOFF_PENDING="$HANDOFF_MARK_DIR/handoff-pending.json"
if [ -f "$HANDOFF_PENDING" ]; then
  if command -v python3 >/dev/null 2>&1; then
    pending_branch=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('branch',''))
except Exception:
    pass
" "$HANDOFF_PENDING")
  else
    pending_branch=$(sed -n 's/.*\"branch\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' \
                     "$HANDOFF_PENDING" | head -1)
  fi
  [ -n "$output" ] && output+=$'\n'
  output+="⚠ Last session left uncommitted work on ${pending_branch:-a feature branch} with no handoff — run /handoff to capture it"
  rm -f "$HANDOFF_PENDING"
fi

if [ -f "$NEXT_REFRESH" ]; then
  # First-session synchronous refresh if no cache exists.
  if [ ! -f "$NEXT_CACHE" ]; then
    bash "$NEXT_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true
  else
    # Background refresh if cache is older than TTL.
    cache_age=$(( $(date +%s) - $(stat -c %Y "$NEXT_CACHE" 2>/dev/null \
                                  || stat -f %m "$NEXT_CACHE" 2>/dev/null \
                                  || echo 0) ))
    if [ "$cache_age" -gt "$NEXT_TTL_SECONDS" ]; then
      ( bash "$NEXT_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
      disown 2>/dev/null || true
    fi
  fi

  if [ -f "$NEXT_CACHE" ]; then
    # Extract fields with python3 (preferred) or sed fallback.
    if command -v python3 >/dev/null 2>&1; then
      next_block=$(python3 - "$NEXT_CACHE" <<'PY'
import json, os, re, sys
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f)
except Exception:
    sys.exit(0)

# Defence in depth: the cache writer already scrubs ASCII control
# characters from author-controlled strings (issue titles, body
# lines), but if the cache was hand-edited or written by an older
# version of the script, scrub again here so the boot banner
# can never render terminal-escape sequences from remote input.
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

def latest_cache_err():
    err_path = os.path.join(os.path.dirname(sys.argv[1]), "next-cache.err")
    try:
        with open(err_path, encoding="utf-8", errors="replace") as f:
            lines = [scrub(ln.strip()) for ln in f if ln.strip()]
    except Exception:
        return ""
    return lines[-1] if lines else ""

err = cache.get("error")
no_remote = cache.get("no_gh_remote", False)
issue = cache.get("issue")

lines = []
if err == "gh-unavailable":
    lines.append("[Next-up] ERROR: gh CLI not available — cannot read next-up state.")
    lines.append("  → Install: https://cli.github.com/")
    lines.append("  → Authenticate: gh auth login")
    lines.append("  → Then refresh: bash scripts/refresh-next-cache.sh")
elif err == "azure-devops-unavailable":
    lines.append("[Next-up] ERROR: Azure DevOps backend unavailable — cannot read next-up state.")
    detail = latest_cache_err()
    if detail:
        lines.append(f"  → {detail}")
    lines.append("  → Check Azure CLI auth/config, then refresh: bash scripts/refresh-next-cache.sh")
elif no_remote:
    pass  # silent skip; not a GH project
elif err:
    lines.append(f"[Next-up] (cache error: {scrub(err)}; see .arboretum/next-cache.err)")
elif issue is None:
    lines.append("[Next-up] (no issue queued — run /handoff to set one)")
else:
    n = issue.get("number")
    title = scrub(issue.get("title", ""))
    lines.append(f"[Next-up] #{n}: {title}")
    if issue.get("body_empty"):
        lines.append("  (body empty — readiness check would fail)")
    for ln in issue.get("body_first_lines", [])[:5]:
        lines.append(f"  {scrub(ln)}")
    handoff = cache.get("handoff")
    # The handoff field is a discriminated three-way union (per
    # docs/contracts/refresh-next-cache.contract.md RNC-3): null,
    # a normal dict, or an error dict {"error": "fetch-failed", ...}.
    # Check the error case FIRST — without this, an error dict would
    # fall through to .get("next_action", "") returning "" and skip
    # silently, re-introducing the bug at the consumer (PR 4 design D3).
    if isinstance(handoff, dict) and handoff.get("error") == "fetch-failed":
        lines.append("  → (handoff fetch failed — see .arboretum/next-cache.err)")
    elif handoff:
        na = scrub(handoff.get("next_action", ""))
        if na:
            lines.append(f"  → Next action: {na}")
        prose = scrub(handoff.get("body", ""))
        if prose:
            lines.append(f"  {prose}")
    url = issue.get("url", "")
    if url:
        lines.append(f"  → {scrub(url)}")
print("\n".join(lines))
PY
)
    else
      # Minimal sed fallback. Handles the three states bare-bones.
      next_block=""
      if grep -q '"error":[[:space:]]*"gh-unavailable"' "$NEXT_CACHE"; then
        next_block="[Next-up] ERROR: gh CLI not available — cannot read next-up state."$'\n'"  → Install: https://cli.github.com/"$'\n'"  → Authenticate: gh auth login"$'\n'"  → Then refresh: bash scripts/refresh-next-cache.sh"
      elif grep -q '"error":[[:space:]]*"azure-devops-unavailable"' "$NEXT_CACHE"; then
        next_block="[Next-up] ERROR: Azure DevOps backend unavailable — cannot read next-up state."$'\n'"  → Check Azure CLI auth/config, then refresh: bash scripts/refresh-next-cache.sh"
      elif grep -q '"no_gh_remote":[[:space:]]*true' "$NEXT_CACHE"; then
        next_block=""
      elif grep -q '"issue":[[:space:]]*null' "$NEXT_CACHE"; then
        next_block="[Next-up] (no issue queued — run /handoff to set one)"
      else
        n=$(sed -n 's/.*"number":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$NEXT_CACHE" | head -1)
        t=$(sed -n 's/.*"title":[[:space:]]*"\([^"]*\)".*/\1/p' "$NEXT_CACHE" | head -1)
        next_block="[Next-up] #${n}: ${t}"
      fi
    fi

    if [ -n "$next_block" ]; then
      output+=$'\n'"$next_block"
    fi
  fi
fi

# ── Workspace orientation (#375) ─────────────────────────────────────
WORKSPACE_CACHE="$PROJECT_DIR/.arboretum/workspace-cache.json"
WORKSPACE_REFRESH="$PROJECT_DIR/scripts/refresh-workspace-cache.sh"
if [ -f "$WORKSPACE_REFRESH" ]; then
  # Refresh SYNCHRONOUSLY every boot — no TTL/background like next-cache. The
  # staleness rail must reflect THIS session's refs: a backgrounded fetch would
  # read last session's refs and could falsely report "current ✓". The script
  # self-bounds its own fetch (5s timeout), so the worst-case boot cost is
  # capped. `|| true` keeps a refresh failure from ever aborting the hook.
  bash "$WORKSPACE_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true
  if [ -f "$WORKSPACE_CACHE" ] && command -v python3 >/dev/null 2>&1; then
    ws_block=""   # ensure set under `set -u` even if the substitution is skipped
    # $NEXT_CACHE may not exist (its refresh is TTL-gated above); the renderer
    # reads it inside a try/except and degrades to no mode-B correlation.
    ws_block=$(python3 - "$WORKSPACE_CACHE" "$NEXT_CACHE" <<'PY'
import json, re, sys
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s): return _CTRL.sub("", s) if isinstance(s, str) else s
try:
    ws = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if ws.get("error"):   # not-a-git-repo, python3-unavailable, fetch-failed, … → stay
    sys.exit(0)        # silent. A degraded cache has current_branch:null, which would
                       # otherwise misrender as a false "detached HEAD" warning (Copilot #376).

branch = scrub(ws.get("current_branch")) or "(detached HEAD)"
dirty, dc = ws.get("dirty"), ws.get("dirty_count", 0)
main = ws.get("main") or {}
mb = main.get("behind")
ma = main.get("ahead")
up = ws.get("current_upstream") or {}
pr = ws.get("open_pr")
fetch_ok = ws.get("fetch_ok")

# next-up correlation (mode B): handoff-recorded branch only, no fuzzy match
recorded_branch = None; next_num = None
try:
    nc = json.load(open(sys.argv[2]))
    issue = nc.get("issue") or {}
    next_num = issue.get("number")
    h = nc.get("handoff")
    if isinstance(h, dict) and not h.get("error"):
        recorded_branch = scrub(h.get("branch")) or None
except Exception:
    pass

# A recorded branch is only resumable if it still exists locally or as a
# worktree — otherwise route to the fresh-branch path, not a dead branch
# (Codex #376 review).
detached = ws.get("current_branch") is None
_local = set(ws.get("local_branches") or [])
_wt = {w.get("branch") for w in (ws.get("worktrees") or []) if w.get("branch")}
recorded_exists = bool(recorded_branch) and (recorded_branch in _local or recorded_branch in _wt)

# header (compact, only signal-bearing segments). "(current ✓)" shows ONLY
# when drift is KNOWN to be 0 — mb is None when origin/main is missing or
# unreachable, and claiming "current" then would contradict the
# "remote unreachable" segment (Codex #376 review).
if branch != "main":
    seg = [branch]
elif mb == 0 and main.get("fresh"):
    seg = ["main (current ✓)"]   # only when drift is known 0 AND main's own fetch succeeded
else:
    seg = ["main"]  # mb None/unknown, mb > 0 (behind, shown separately), or main's
                    # fetch failed (stale refs — never claim "current": Codex #376)
if dirty: seg.append(f"{dc} uncommitted file" + ("s" if dc != 1 else ""))
if mb: seg.append(f"main {mb} behind ⚠")
if ma: seg.append(f"main {ma} unpushed ⚠")  # local commits on main not on its upstream
if isinstance(pr, dict): seg.append(f"open PR #{pr.get('number')}")
# Suppress the branch-upstream segment when on main: current_upstream is then
# the SAME comparison as the main rail, so it would duplicate it (Codex #376).
if up.get("behind") and branch != "main": seg.append(f"branch {up['behind']} behind {scrub(up.get('name'))}")
if fetch_ok is False: seg.append("remote unreachable — staleness unknown")

# routing precedence → one recommended action line.
# Order matters: B-resume (resuming a /handoff-recorded branch) is NOT a
# fresh-branch operation, so main drift must NOT block it — it is checked
# BEFORE the behind-main (D) blocker. Design: "main drift blocks only the
# fresh-branch path." (Copilot #376 review.)
if detached:                                         # detached HEAD — design edge case
    action = "Detached HEAD — checkout a branch before starting work."
elif dirty:                                          # A — resume WIP
    action = "Resume WIP here. Sync main separately when ready — don't rebase onto stale main mid-work."
elif isinstance(pr, dict):                           # E — land/respond to PR
    action = f"Respond to PR: /land. I'll `git pull --ff-only` the branch first."
elif recorded_exists:                                # B — resume recorded branch (drift does not block)
    action = f"Next-up #{next_num} → branch `{recorded_branch}` (resume) or fresh branch off updated main."
elif mb:                                             # D — fresh-branch blocker (incl. recorded-but-missing + stale main)
    if branch == "main":
        action = "Sync before branching: `git pull --ff-only` (I'll run it). Branching off stale main is the usual conflict cause."
    else:
        # On a clean non-main branch: `git pull --ff-only` would pull THIS
        # branch, not main — so direct to main first (Codex #376).
        action = f"`main` is {mb} behind — switch to main and sync (`git checkout main && git pull --ff-only`) before cutting a new branch."
elif recorded_branch:                                # B — recorded branch is gone, main current
    action = f"Next-up #{next_num}'s recorded branch `{recorded_branch}` no longer exists — I'll create a fresh branch off main."
elif next_num:                                       # B/D — next-up, no recorded branch
    action = f"Next-up #{next_num} has no recorded branch — I'll create a feat/ off main, or start an independent fix the same way."
else:                                                # C — survey via roadmap
    action = None  # nothing to recommend; roadmap pulse already prints

# Silence rule: emit NOTHING when there is zero signal and no action — i.e.
# on clean `main`, not behind, no dirty/PR/upstream-drift, fetch ok, no
# next-up. Being on a feature branch or detached HEAD is itself signal.
on_feature = branch != "main"
has_signal = (bool(action) or dirty or bool(mb) or bool(ma) or isinstance(pr, dict)
              or bool(up.get("behind")) or (fetch_ok is False) or on_feature)
if not has_signal:
    sys.exit(0)

lines = [f"[Workspace] {' · '.join(seg)}"]
if action: lines.append(f"  → {action}")
print("\n".join(lines))
PY
)
    [ -n "$ws_block" ] && output+=$'\n'"$ws_block"
  fi
fi

# ── Pipeline state (WS9 D7) ──────────────────────────────────────────
# Three lines: Stage (from active-stage-cache); Last action (most recent
# stage-transition log comment); Last session (most recent `summary`
# action log comment). All three are independent — each shows only if
# its data is available.
STAGE_CACHE="$PROJECT_DIR/.arboretum/active-stage-cache.json"
LOG_CACHE="$PROJECT_DIR/.arboretum/log-comments-cache.json"

if [ -f "$STAGE_CACHE" ] && command -v python3 >/dev/null 2>&1; then
  pipeline_block=$(python3 - "$STAGE_CACHE" "$LOG_CACHE" <<'PY'
import json, os, re, sys
# Defense in depth: the cache writer (refresh-stage-cache.sh) already
# scrubs ASCII control characters from author-controlled strings, but
# if the cache was hand-edited or written by an older script version,
# scrub again here so the boot banner can never render terminal-escape
# sequences from remote input. Same pattern as session-start.sh's
# next-up block (which scrubs next-cache.json's content for the same
# reason).
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s
try:
    sc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
lines = []
if sc.get("stage"):
    lines.append(f"Stage: {scrub(sc['stage'])}")
# Log-comments cache may be absent (first session before any logging happened).
try:
    lc = json.load(open(sys.argv[2]))
except Exception:
    lc = []

# `dispatched` and `repair` are NOT in the transition set — see WS9 D7:
# Last action surfaces stage lifecycle, not mid-stage handoffs or repair audit events.
transition_actions = {"entered", "exited", "skipped", "re-entered"}

def parse(c):
    """Extract (ts, stage, action, rest) from a log comment, or None."""
    return re.search(r"^- (\S+) — (\S+) (\S+)(?:, (.+))?$", c.get("body",""), re.M)

last_transition = None
last_summary = None
for c in lc:
    m = parse(c)
    if not m: continue
    ts, stage, action, rest = m.group(1), m.group(2), m.group(3), m.group(4) or ""
    if action in transition_actions:
        last_transition = (ts, stage, action, rest)
    elif action == "summary":
        last_summary = (ts, stage, action, rest)
if last_transition:
    ts, stage, action, rest = last_transition
    extra = f", {scrub(rest)}" if rest else ""
    lines.append(f"Last action: {scrub(stage)} {scrub(action)}{extra} ({scrub(ts)})")
if last_summary:
    ts, _, _, rest = last_summary
    # D5 reader contract: summary may be quoted (when it contains `, `,
    # `"`, `\`, or `\n`) or unquoted (when it's a plain string). The
    # writer only quotes when forced — typical summaries with spaces but
    # no comma render unquoted. Try quoted first; fall back to unquoted.
    text = None
    m = re.search(r'summary:\s*"((?:[^"\\]|\\.)*)"', rest)
    if m:
        # Stateful left-to-right unescape — sequential `.replace()` calls
        # cannot correctly decode `C:\\new` (literal backslash + `n`)
        # because they can't distinguish `\n` (escape sequence) from `\`
        # + literal `n` after the writer has doubled the backslash.
        # Walk once and consume escape pairs atomically. (Codex R2-3.)
        raw = m.group(1)
        out = []
        i = 0
        while i < len(raw):
            if raw[i] == '\\' and i + 1 < len(raw):
                c = raw[i+1]
                if c == 'n':
                    out.append(' ')   # D5: collapse to space (single-sentence summary)
                elif c == '\\':
                    out.append('\\')
                elif c == '"':
                    out.append('"')
                else:
                    out.append(raw[i:i+2])  # unknown escape — preserve verbatim
                i += 2
            else:
                out.append(raw[i])
                i += 1
        text = ''.join(out)
    else:
        # Unquoted: split rest on `, ` (safe because the writer only
        # quotes when value contains `, `, so unquoted values never
        # contain the delimiter).
        for pair in rest.split(", "):
            if pair.startswith("summary:"):
                text = pair[len("summary:"):].strip()
                break
    if text is None:
        text = rest
    lines.append(f"Last session: {scrub(text)} ({scrub(ts)})")
print("\n".join(lines))
PY
)
  if [ -n "$pipeline_block" ]; then
    [ -n "$output" ] && output+=$'\n'
    output+="$pipeline_block"
  fi
fi

# ── Arboretum update check ───────────────────────────────────────────
# Surface a one-line notice if the installed plugin is behind the latest
# published release. Cache at .arboretum/update-cache.json; refreshed by
# scripts/refresh-update-cache.sh with a 24-hour TTL (background after
# first run, same pattern as next-cache). Silent on error or missing gh.

UPDATE_CACHE="$PROJECT_DIR/.arboretum/update-cache.json"
UPDATE_REFRESH="$PROJECT_DIR/scripts/refresh-update-cache.sh"
UPDATE_TTL_SECONDS=86400

if [ -f "$UPDATE_REFRESH" ]; then
  if [ ! -f "$UPDATE_CACHE" ]; then
    bash "$UPDATE_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true
  else
    cache_age=$(( $(date +%s) - $(stat -c %Y "$UPDATE_CACHE" 2>/dev/null \
                                  || stat -f %m "$UPDATE_CACHE" 2>/dev/null \
                                  || echo 0) ))
    if [ "$cache_age" -gt "$UPDATE_TTL_SECONDS" ]; then
      ( bash "$UPDATE_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
      disown 2>/dev/null || true
    fi
  fi

  update_block=""
  if [ -f "$UPDATE_CACHE" ]; then
    if command -v python3 >/dev/null 2>&1; then
      update_block=$(python3 - "$UPDATE_CACHE" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f)
except Exception:
    sys.exit(0)
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
if cache.get("update_available"):
    iv = _CTRL.sub("", cache.get("installed_version") or "?")
    lv = _CTRL.sub("", cache.get("latest_version") or "?")
    print(f"[Arboretum] Update available: v{iv} → v{lv} — run /plugin update arboretum to upgrade.")
elif cache.get("error") == "manifest-not-found":
    print("[Arboretum] Plugin not found — install with /plugin install arboretum.")
elif cache.get("error") == "gh-unavailable":
    print("[Arboretum] Could not check latest release — gh unavailable; install gh or run gh auth status.")
elif cache.get("error") in ("gh-call-failed", "no-release"):
    iv = _CTRL.sub("", cache.get("installed_version") or "?")
    print(f"[Arboretum] Could not check latest release — release lookup failed; using installed v{iv}.")
PY
) || true
    else
      _scrub_ctrl() { printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177-\237'; }
      if grep -q '"update_available"[[:space:]]*:[[:space:]]*true' "$UPDATE_CACHE" 2>/dev/null; then
        _iv=$(sed -n 's/.*"installed_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_CACHE" | head -1)
        _lv=$(sed -n 's/.*"latest_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_CACHE" | head -1)
        _iv="$(_scrub_ctrl "$_iv")"
        _lv="$(_scrub_ctrl "$_lv")"
        update_block="[Arboretum] Update available: v${_iv:-?} → v${_lv:-?} — run /plugin update arboretum to upgrade."
      elif grep -q '"error"[[:space:]]*:[[:space:]]*"manifest-not-found"' "$UPDATE_CACHE" 2>/dev/null; then
        update_block="[Arboretum] Plugin not found — install with /plugin install arboretum."
      elif grep -q '"error"[[:space:]]*:[[:space:]]*"gh-unavailable"' "$UPDATE_CACHE" 2>/dev/null; then
        update_block="[Arboretum] Could not check latest release — gh unavailable; install gh or run gh auth status."
      elif grep -Eq '"error"[[:space:]]*:[[:space:]]*"(gh-call-failed|no-release)"' "$UPDATE_CACHE" 2>/dev/null; then
        _iv=$(sed -n 's/.*"installed_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_CACHE" | head -1)
        _iv="$(_scrub_ctrl "$_iv")"
        update_block="[Arboretum] Could not check latest release — release lookup failed; using installed v${_iv:-?}."
      fi
    fi
  fi
  if [ -n "${update_block:-}" ]; then
    output+=$'\n'"$update_block"
  fi
fi

# ── Project-tree staleness check (#316) ─────────────────────────────
# If the project's install-manifest.json records a framework_version
# older than the currently-installed plugin, nudge the user to run
# /upgrade. Only fires when the manifest exists (i.e. in a downstream
# project that has run /init, never in arboretum-dev itself) and when
# jq is available. Uses the same installed_version source as the
# update-available block above (update-cache.json).

INSTALL_MANIFEST="$PROJECT_DIR/.arboretum/install-manifest.json"
if [ -f "$INSTALL_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  _mfv=$(jq -r '.framework_version // empty' "$INSTALL_MANIFEST" 2>/dev/null || true)
  # installed_version from update-cache.json — same source as update-available block.
  _instv=""
  if [ -f "$UPDATE_CACHE" ]; then
    _instv=$(jq -r '.installed_version // empty' "$UPDATE_CACHE" 2>/dev/null || true)
  fi
  # Defense in depth (CLAUDE.md § scrub author-controlled content): these version
  # strings originate from the installed plugin's plugin.json — remote-sourced for
  # adopters — and flow into the boot banner (Claude's context). Strip ASCII control
  # chars before rendering, matching the next-up / stage-cache blocks' scrub convention.
  _mfv=$(printf '%s' "$_mfv" | LC_ALL=C tr -d '\000-\037\177-\237')
  _instv=$(printf '%s' "$_instv" | LC_ALL=C tr -d '\000-\037\177-\237')
  if [ -n "$_mfv" ] && [ -n "$_instv" ] && [ "$_mfv" != "$_instv" ]; then
    # Fire only when manifest version sorts strictly older than installed.
    _newer=$(printf '%s\n%s\n' "$_mfv" "$_instv" | sort -V | tail -1)
    if [ "$_newer" = "$_instv" ]; then
      output+=$'\n'"[Arboretum] Project tree is behind the installed plugin ($_mfv → $_instv) — run /upgrade."
    fi
  fi
fi

# ── Build-cycle state ────────────────────────────────────────────────
# When a build cycle is in flight on the current branch, surface the
# observable state so the human and LLM see "where am I" without
# re-deriving it. Detection is shell-only — no gh calls. Per
# docs/specs/session-start-cycle-state.spec.md (issue #167).
#
# Forward-compat: CYCLE_MODE will switch from "spec" to "workflow"
# when OQ5 step 1 lands (#164). Detection logic is structured around
# the CYCLE_MODE variable so the directories searched can change
# without rewriting the matching logic.

CYCLE_MODE="${ARBORETUM_CYCLE_MODE:-spec}"
CYCLE_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -n "$CYCLE_BRANCH" ] && [ "$CYCLE_BRANCH" != "main" ] && [ "$CYCLE_BRANCH" != "master" ]; then
  # Strip prefix to get topic substring (D2)
  CYCLE_TOPIC="${CYCLE_BRANCH#feat/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#fix/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#docs/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#chore/}"

  # Search dirs depend on mode (D6 forward-compat). Use an array for
  # PLAN_DIRS so paths containing spaces survive iteration.
  if [ "$CYCLE_MODE" = "spec" ]; then
    DESIGN_DIR="$PROJECT_DIR/docs/superpowers/specs"
    PLAN_DIRS=("$PROJECT_DIR/docs/plans" "$PROJECT_DIR/docs/superpowers/plans")
  else
    # Future: workflows-mode dirs
    DESIGN_DIR="$PROJECT_DIR/docs/superpowers/specs"
    PLAN_DIRS=("$PROJECT_DIR/docs/plans" "$PROJECT_DIR/docs/superpowers/plans")
  fi

  # Find matching design spec by branch-name substring match (D2)
  CYCLE_SPEC=""
  if [ -d "$DESIGN_DIR" ]; then
    CYCLE_SPEC=$(ls -t "$DESIGN_DIR"/*"$CYCLE_TOPIC"*.md 2>/dev/null | head -1 || true)
  fi

  # Find matching plan
  CYCLE_PLAN=""
  for plan_dir in "${PLAN_DIRS[@]}"; do
    [ -d "$plan_dir" ] || continue
    found=$(ls -t "$plan_dir"/*"$CYCLE_TOPIC"*.md 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
      CYCLE_PLAN="$found"
      break
    fi
  done

  # Trigger condition (D1): emit section only if either present
  if [ -n "$CYCLE_SPEC" ] || [ -n "$CYCLE_PLAN" ]; then
    cycle_block="[Build cycle]   branch: $CYCLE_BRANCH"

    if [ -n "$CYCLE_SPEC" ]; then
      cycle_block+=$'\n'"                spec:   $(basename "$CYCLE_SPEC")"
    fi

    if [ -n "$CYCLE_PLAN" ]; then
      # Plan-checkbox parsing (D3 input). grep -c exits 1 on no matches but
      # still prints "0"; capture the value via assignment, fall back via
      # the failure branch to avoid pipefail double-echo.
      checked=$(grep -c '^[[:space:]]*-[[:space:]]*\[x\]' "$CYCLE_PLAN" 2>/dev/null) || checked=0
      unchecked=$(grep -c '^[[:space:]]*-[[:space:]]*\[ \]' "$CYCLE_PLAN" 2>/dev/null) || unchecked=0
      total=$((checked + unchecked))

      if [ "$total" -gt 0 ]; then
        cycle_block+=$'\n'"                plan:   $(basename "$CYCLE_PLAN") (${checked}/${total} tasks complete)"
      else
        cycle_block+=$'\n'"                plan:   $(basename "$CYCLE_PLAN")"
      fi

      # Phase inference (D3)
      remaining=$((total - checked))
      if [ "$total" -eq 0 ]; then
        phase="ready to start implementation"
      elif [ "$checked" -eq 0 ]; then
        phase="ready to start implementation"
      elif [ "$checked" -lt "$total" ]; then
        phase="mid-implementation, ${remaining} tasks remain"
      else
        phase="ready for /finish"
      fi
    elif [ -n "$CYCLE_SPEC" ]; then
      # Design spec but no plan
      phase="pre-implementation, settle plan"
    else
      phase=""
    fi

    if [ -n "$phase" ]; then
      cycle_block+=$'\n'"                phase:  $phase"
    fi
    cycle_block+=$'\n'"                next:   run /start to continue"

    output+=$'\n'"$cycle_block"
  fi
fi

# ── Parse register for spec statuses ─────────────────────────────────

if [ -f "$REGISTER" ]; then
  # Extract spec index table rows (lines matching "| something.spec.md |")
  spec_lines=$(grep -E '^\|.*\.spec\.md' "$REGISTER" 2>/dev/null || true)

  if [ -n "$spec_lines" ]; then
    draft_count=0
    active_count=0
    stale_count=0
    stale_specs=""
    draft_specs=""

    while IFS='|' read -r _ spec status _ _; do
      spec=$(echo "$spec" | xargs)
      status=$(echo "$status" | xargs)
      case "$status" in
        draft)
          ((draft_count += 1)) || true
          draft_specs+="$spec, "
          ;;
        active) ((active_count += 1)) || true ;;
        stale)
          ((stale_count += 1)) || true
          stale_specs+="$spec, "
          ;;
      esac
    done <<< "$spec_lines"

    output+=$'\n'"[Spec Status] draft:$draft_count active:$active_count stale:$stale_count"

    if [ -n "$stale_specs" ]; then
      output+=$'\n'"[Stale] ${stale_specs%, }"
      output+=$'\n'"  → $stale_count spec(s) stale — run /consolidate to reconcile or /health-check for details."
    fi
    if [ -n "$draft_specs" ]; then
      output+=$'\n'"[Draft] ${draft_specs%, }"
    fi
  fi
fi

# ── Check register staleness ─────────────────────────────────────────

if [ -f "$REGISTER" ] && [ -d "$PROJECT_DIR/docs/specs" ]; then
  register_stale=false
  for spec_file in "$PROJECT_DIR"/docs/specs/*.spec.md; do
    [ -f "$spec_file" ] || continue
    if [ "$spec_file" -nt "$REGISTER" ]; then
      register_stale=true
      break
    fi
  done
  if [ "$register_stale" = true ]; then
    output+=$'\n'"[Register] REGISTER.md may be stale — spec files are newer than the register."
    output+=$'\n'"  → Why: Stale register data causes incorrect staleness checks and ownership lookups."
    output+=$'\n'"    Run scripts/generate-register.sh to resync."
  fi
fi

# ── Check version pin staleness ──────────────────────────────────────

if [ -f "$CONTRACTS" ] && [ -d "$DEFS_DIR" ]; then
  stale=""

  # Extract definition paths and pinned versions from contracts.yaml
  # Format: definitions/foo.md: v1
  pins=$(grep -E '^\s+definitions/' "$CONTRACTS" 2>/dev/null | sed 's/#.*//' || true)

  while IFS=: read -r def_path pinned_version; do
    [ -z "$def_path" ] && continue
    def_path=$(echo "$def_path" | xargs)
    pinned_version=$(echo "$pinned_version" | xargs)
    [ -z "$pinned_version" ] && continue

    def_file="$PROJECT_DIR/docs/$def_path"
    if [ -f "$def_file" ]; then
      # Extract current version from definition file's ## Version section
      current_version=$(grep -A1 '^## Version' "$def_file" 2>/dev/null \
        | grep -oE 'v[0-9]+' | head -1 || true)

      if [ -n "$current_version" ] && [ "$current_version" != "$pinned_version" ]; then
        stale+="  $def_path: pinned=$pinned_version current=$current_version"$'\n'
      fi
    fi
  done <<< "$pins"

  if [ -n "$stale" ]; then
    output+=$'\n'"[Stale Version Pins] Definition versions have drifted from contracts.yaml:"$'\n'"$stale"
    output+="  → Why: Implementing against stale pins risks silent drift between code and contracts."
    output+=$'\n'"    Run /health-check or scripts/sync-contracts.sh to reconcile."
  fi
fi

# ── Layer upgrade suggestions ────────────────────────────────────────

if [ "$LAYER" -lt 1 ]; then
  # Count specs to suggest Layer 1
  spec_count=0
  if [ -d "$PROJECT_DIR/docs/specs" ]; then
    spec_count=$(find "$PROJECT_DIR/docs/specs" -type d -name '_*' -prune -o -name "*.spec.md" -type f -print 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "$spec_count" -ge 3 ]; then
    output+=$'\n'"[Layer Suggestion] $spec_count specs detected at Layer 0."
    output+=$'\n'"  → Why: Layer 1 adds ownership context on every edit and auto-register updates — useful once you have 3+ specs."
    output+=$'\n'"    Set layer: 1 in .arboretum.yml to activate."
  fi
fi

if [ "$LAYER" -lt 2 ]; then
  # Check for multi-author or CI to suggest Layer 2
  suggest_l2=false
  if [ -d "$PROJECT_DIR/.github/workflows" ]; then
    ci_count=$(find "$PROJECT_DIR/.github/workflows" -name "*.yml" -o -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    [ "$ci_count" -gt 0 ] && suggest_l2=true
  fi
  if [ "$suggest_l2" = false ]; then
    author_count=$( { git -C "$PROJECT_DIR" log --format='%ae' 2>/dev/null || true; } | sort -u | wc -l | tr -d ' ')
    [ "$author_count" -ge 2 ] && suggest_l2=true
  fi
  if [ "$suggest_l2" = true ]; then
    output+=$'\n'"[Layer Suggestion] CI workflows or multiple git authors detected at Layer $LAYER."
    output+=$'\n'"  → Why: Layer 2 adds version-pin enforcement, branch protection, and post-commit drift detection — valuable for multi-author projects."
    output+=$'\n'"    Set layer: 2 in .arboretum.yml to activate."
  fi
fi

# ── Active skills by layer ───────────────────────────────────────────

SKILLS_DIR="$PROJECT_DIR/.claude/skills"
if [ -d "$SKILLS_DIR" ]; then
  # Build skill lists per layer
  layer0_skills=""
  layer1_skills=""
  layer2_skills=""

  for skill_dir in "$SKILLS_DIR"/*/; do
    [ ! -d "$skill_dir" ] && continue
    skill_file="$skill_dir/SKILL.md"
    [ ! -f "$skill_file" ] && continue
    skill_name="$(basename "$skill_dir")"

    # Extract layer from YAML frontmatter (between --- markers)
    skill_layer=$(sed -n '/^---$/,/^---$/{ s/^layer:[[:space:]]*\([0-9]\).*/\1/p; }' "$skill_file")
    [ -z "$skill_layer" ] && continue

    case "$skill_layer" in
      0) layer0_skills+="/$skill_name, " ;;
      1) layer1_skills+="/$skill_name, " ;;
      2) layer2_skills+="/$skill_name, " ;;
    esac
  done

  active_output=""
  if [ -n "$layer0_skills" ] && [ "$LAYER" -ge 0 ]; then
    active_output+="Layer 0: ${layer0_skills%, }"
  fi
  if [ -n "$layer1_skills" ] && [ "$LAYER" -ge 1 ]; then
    active_output+="; Layer 1: ${layer1_skills%, }"
  fi
  if [ -n "$layer2_skills" ] && [ "$LAYER" -ge 2 ]; then
    active_output+="; Layer 2: ${layer2_skills%, }"
  fi

  if [ -n "$active_output" ]; then
    output+=$'\n'"[Active Skills] $active_output"
  fi
fi

# ── Roadmap orientation (issue #152) ─────────────────────────────────
# render-run.sh exits silently when roadmap.config.yaml is absent, so this
# is a no-op on projects that haven't instantiated the roadmap system.
# Nag machinery runs inside render-run.sh before the gh guard.

ROADMAP_RENDER="$PROJECT_DIR/scripts/roadmap/render-run.sh"
if [ -x "$ROADMAP_RENDER" ]; then
  orientation_status=0
  orientation_text="$(bash "$ROADMAP_RENDER" --condensed 2>/dev/null)" || orientation_status=$?
  if [ -n "$orientation_text" ]; then
    [ -n "$output" ] && output+=$'\n'
    output+="$orientation_text"
  elif [ -f "$PROJECT_DIR/roadmap.config.yaml" ] && [ "$orientation_status" -ne 0 ]; then
    [ -n "$output" ] && output+=$'\n'
    output+="[roadmap] Configured, but render failed — run /roadmap run for details."
  fi
elif [ -f "$PROJECT_DIR/roadmap.config.yaml" ]; then
  [ -n "$output" ] && output+=$'\n'
  output+="[roadmap] Renderer missing from project tree — run /upgrade."
fi

# ── Output ───────────────────────────────────────────────────────────

if [ -n "$output" ]; then
  echo "$output"
fi

exit 0
