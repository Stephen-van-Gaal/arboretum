#!/usr/bin/env bash
# owner: project-infrastructure
# refresh-next-cache.sh — Refresh .arboretum/next-cache.json from the tracker.
#
# Reads the open tracker item carrying the `next-up` label (at most one) via
# the configured backend and writes a small JSON cache that `session-start.sh`
# consumes.
#
# Cache shape (as actually written by this script):
#   {
#     "fetched_at": "<ISO-8601 UTC>",
#     "issue": null | {
#       "number": <int>,
#       "title": "<string, control-char-stripped>",
#       "url": "<string>",
#       "body_first_lines": ["<line, control-char-stripped>", ...],
#       "body_empty": true | false,
#       "labels": ["<string>", ...],
#       "updated_at": "<ISO-8601 UTC>"
#     },
#     "handoff": null | { posted_at, branch, next_action, body }   # success — see below
#                    | { "error": "fetch-failed", "detail": "<string>" }  # comment-fetch failure
#     "no_gh_remote": true | false,
#     "error": null | "gh-unavailable" | "gh-call-failed"
#                  | "azure-devops-unavailable" | "azure-devops-call-failed"
#                  | "backend-unavailable" | "tracker-call-failed"
#                  | "python3 unavailable; issue details omitted in fallback cache"
#   }
#
# The `handoff` field is a discriminated three-way union (per
# refresh-next-cache.contract.md RNC-3):
#   - `null`             : no arbo-handoff-marked comment exists on the issue
#   - normal dict        : handoff comment fetched successfully
#                          {"posted_at": "<ISO-8601 UTC | branch-marker timestamp>",
#                           "branch":    "<branch name, control-char-stripped>",
#                           "next_action": "<string, control-char-stripped>",
#                           "body":      "<prose lines joined with spaces, control-char-stripped>"}
#   - error dict (NEW)   : tracker comment fetch was attempted but exited
#                          non-zero. The first stderr line is captured in `detail`
#                          (control-char-stripped); full diagnostic still written to
#                          .arboretum/next-cache.err. Cache write succeeds (exit 0) — the
#                          failure is recorded *in* the cache, not *about* the cache.
#                          Replaces the pre-#264 silent-null-on-failure behaviour.
#
# Title and body lines are stripped of ASCII control characters
# (including \x1b ANSI escape introducers) when stored, so the
# session-start banner can render them as-is without risk of
# remote-controlled terminal-escape injection (issue text is
# author-controlled tracker content).
#
# Usage:
#   bash scripts/refresh-next-cache.sh [project-dir]
#
# Exit codes:
#   0  — cache written (issue found, no issue, or no tracker remote)
#   1  — configured tracker backend missing or unauthenticated (cache also reflects this)
#   2  — tracker call failed for some other reason
#
# Safe to call concurrently — write_cache uses a per-process mktemp
# tempfile and atomic rename, so racing refreshes never clobber each
# other's in-flight write.
#
# Body extraction prefers python3 (always available on supported
# systems); the no-python3 fallback emits a minimal cache shape with
# issue: null and a descriptive error rather than hand-rolling JSON
# from shell-interpolated strings (which would break on titles with
# quotes/backslashes).

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/roadmap/lib.sh
. "$SCRIPT_DIR/roadmap/lib.sh"

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/next-cache.json"
ERR_FILE="$CACHE_DIR/next-cache.err"
ROADMAP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export ROADMAP_BACKEND

mkdir -p "$CACHE_DIR"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_cache() {
  # $1 = JSON content. Use a per-process temp file (mktemp) so a
  # concurrent refresh — e.g. the hook's background refresh racing
  # the /handoff post-apply refresh — can't clobber a shared .tmp
  # path mid-write. The atomic rename still wins last-writer; the
  # cache is always either the previous good state or the latest
  # complete write, never a truncated mash-up.
  local tmp
  tmp=$(mktemp "$CACHE_DIR/next-cache.json.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

write_err() {
  # $1 = diagnostic line
  printf '[%s] %s\n' "$(now_iso)" "$1" >> "$ERR_FILE"
}

# ── Shared helper: run epic-walk + perform auto-advance label move ────
# F1: factored helper used by BOTH the normal (open issue) path and the
# closed-next-up path so auto-advance logic is not duplicated.
#
# Args: $1 = next-up issue number (may be closed)
# Sets: epic_json, auto_to, auto_from in the caller's scope
# Writes: cache to CACHE_FILE via write_cache (with issue:null for the
#         closed path — caller is responsible for the issue field value)
#
# Returns 0 always (fail-soft).
run_epic_walk_and_cache_if_advance() {
  local _nu="$1"
  local _epic_json _epic_out _auto_to _auto_from _advance_ok _rewrite_json
  _epic_json='{"epics_in_flight":[],"auto_advance":null}'
  if [ -f "$SCRIPT_DIR/roadmap/epic-walk.sh" ]; then
    if _epic_out=$( cd "$PROJECT_DIR" && bash "$SCRIPT_DIR/roadmap/epic-walk.sh" --next-up "${_nu}" 2>>"$ERR_FILE" ); then
      [ -n "$_epic_out" ] && _epic_json="$_epic_out"
    else
      write_err "epic-walk failed for closed next-up #${_nu}; epics_in_flight omitted"
    fi
  fi

  _auto_to=$(printf '%s' "$_epic_json" | python3 -c \
    'import json,sys;a=json.load(sys.stdin)["auto_advance"];print(a["to"] if a else "")' \
    2>/dev/null || true)
  _auto_from=$(printf '%s' "$_epic_json" | python3 -c \
    'import json,sys;a=json.load(sys.stdin)["auto_advance"];print(a["from"] if a else "")' \
    2>/dev/null || true)

  if [ -z "$_auto_to" ] || [ -z "$_auto_from" ]; then
    # No auto-advance candidate from closed next-up. If the resolver found
    # epics_in_flight (e.g. all children blocked), write a cache that includes
    # that epic context so the banner can surface the blocked-epic state.
    # Without this, the blocked children that explain "why no advance" are lost
    # and the boot banner shows no epic orientation at all.
    # When epics_in_flight is empty there is nothing to add; let the caller
    # write the standard empty cache (return 0 = "I did not write the cache").
    local _has_epics
    _has_epics=$(printf '%s' "$_epic_json" | python3 -c \
      'import json,sys;d=json.load(sys.stdin);print("yes" if d.get("epics_in_flight") else "no")' \
      2>/dev/null || true)
    if [ "${_has_epics:-no}" != "yes" ]; then
      return 0
    fi
    # Build and write a cache with the blocked-epic context (issue:null, auto_advanced:null).
    local _blocked_cache_json _blocked_epic_file
    _blocked_epic_file=$(mktemp "$CACHE_DIR/epic.json.XXXXXX")
    printf '%s' "$_epic_json" > "$_blocked_epic_file"
    _blocked_cache_json=$(FETCHED_AT="$(now_iso)" python3 - "$_blocked_epic_file" 2>/dev/null <<'PY'
import json, os, re, sys
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s): return _CTRL.sub("", s) if isinstance(s, str) else s
def scrub_epic(e):
    out = dict(e)
    out["title"] = scrub(out.get("title", ""))
    out["active"] = [{**c, "title": scrub(c.get("title", "")), "stage": c.get("stage")}
                     for c in (out.get("active") or [])]
    if out.get("next"):
        out["next"] = {**out["next"], "title": scrub(out["next"].get("title", ""))}
    out["blocked"] = [{**b, "title": scrub(b.get("title", ""))} for b in (out.get("blocked") or [])]
    return out
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        epic_data = json.load(fh)
    epics_in_flight = [scrub_epic(e) for e in epic_data.get("epics_in_flight", [])]
except Exception:
    epics_in_flight = []
cache = {
    "fetched_at": os.environ["FETCHED_AT"],
    "issue": None,
    "handoff": None,
    "no_gh_remote": False,
    "error": None,
    "epics_in_flight": epics_in_flight,
    "auto_advanced": None,
}
print(json.dumps(cache, indent=2))
PY
    )
    rm -f "$_blocked_epic_file"
    if [ -n "$_blocked_cache_json" ]; then
      write_cache "$_blocked_cache_json"
    fi
    # Return so the caller's stamp check detects the write (if any) and skips
    # the standard empty-cache fallback.
    return 0
  fi

  # Build epics_in_flight from the resolver output and write an issue:null cache
  # that includes the auto_advanced field (pending label write below).
  local _epics_json _advance_candidate _cache_json _epic_file
  _epic_file=$(mktemp "$CACHE_DIR/epic.json.XXXXXX")
  printf '%s' "$_epic_json" > "$_epic_file"
  _cache_json=$(FETCHED_AT="$(now_iso)" python3 - "$_epic_file" 2>/dev/null <<'PY'
import json, os, re, sys
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s): return _CTRL.sub("", s) if isinstance(s, str) else s
def scrub_epic(e):
    out = dict(e)
    out["title"] = scrub(out.get("title", ""))
    out["active"] = [{**c, "title": scrub(c.get("title", "")), "stage": c.get("stage")}
                     for c in (out.get("active") or [])]
    if out.get("next"):
        out["next"] = {**out["next"], "title": scrub(out["next"].get("title", ""))}
    out["blocked"] = [{**b, "title": scrub(b.get("title", ""))} for b in (out.get("blocked") or [])]
    return out
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        epic_data = json.load(fh)
    epics_in_flight = [scrub_epic(e) for e in epic_data.get("epics_in_flight", [])]
    auto_advance_candidate = epic_data.get("auto_advance")
except Exception:
    epics_in_flight = []
    auto_advance_candidate = None
cache = {
    "fetched_at": os.environ["FETCHED_AT"],
    "issue": None,
    "handoff": None,
    "no_gh_remote": False,
    "error": None,
    "epics_in_flight": epics_in_flight,
    "auto_advanced": auto_advance_candidate,
}
print(json.dumps(cache, indent=2))
PY
  )
  rm -f "$_epic_file"

  if [ -z "$_cache_json" ]; then
    write_err "closed-next-up auto-advance: python cache build failed for #${_nu}; skipping"
    return 0
  fi
  write_cache "$_cache_json"

  # F2: add-to-target FIRST, then remove-from-source
  _advance_ok=false
  if ( cd "$PROJECT_DIR" && roadmap_tracker_issue_update "$_auto_to" --add-label next-up ) 2>>"$ERR_FILE"; then
    _advance_ok=true
    if ! ( cd "$PROJECT_DIR" && roadmap_tracker_issue_update "$_auto_from" --remove-label next-up ) 2>>"$ERR_FILE"; then
      write_err "closed-next-up auto-advance: --add-label next-up on #${_auto_to} succeeded but --remove-label from #${_auto_from} failed (tolerable transient)"
    fi
  else
    write_err "closed-next-up auto-advance: --add-label next-up on #${_auto_to} failed; label stays on #${_auto_from}"
  fi

  if ! $_advance_ok; then
    # Rewrite cache with auto_advanced:null
    _rewrite_json=$(python3 - "$CACHE_FILE" 2>/dev/null <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c['auto_advanced'] = None
print(json.dumps(c, indent=2))
PY
)
    if [ -n "$_rewrite_json" ]; then
      write_cache "$_rewrite_json"
    fi
  fi
}

# ── Detect git remote (any) ──────────────────────────────────────────
# We don't insist on a remote named `origin` — repos that use
# `upstream`-style workflows would be silently skipped. The selected
# tracker backend decides whether the local repo context is usable.

remote_name=$(git -C "$PROJECT_DIR" remote 2>/dev/null | head -n 1 || true)
if [ -z "$remote_name" ]; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": true,
  "error": null,
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)")"
  exit 0
fi

# ── Detect tracker backend ───────────────────────────────────────────

backend_stderr=$(mktemp "$CACHE_DIR/backend.stderr.XXXXXX")
if ! roadmap_probe_backend_access "$ROADMAP_BACKEND" "$PROJECT_DIR" > /dev/null 2>"$backend_stderr"; then
  backend_unavailable_error="backend-unavailable"
  case "$ROADMAP_BACKEND" in
    github) backend_unavailable_error="gh-unavailable" ;;
    azure-devops) backend_unavailable_error="azure-devops-unavailable" ;;
  esac
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": "%s",
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)" "$backend_unavailable_error")"
  while IFS= read -r _err_line; do
    [ -n "$_err_line" ] && write_err "$_err_line"
  done < "$backend_stderr"
  rm -f "$backend_stderr"
  exit 1
fi
rm -f "$backend_stderr"

# ── Fetch the next-up issue ──────────────────────────────────────────
# Run the tracker command from inside the project dir so the backend picks up
# the right repo from local git config where applicable.

# Capture stdout (the JSON payload) and stderr (warnings/errors)
# separately, so a stderr warning from the tracker doesn't poison the JSON
# we hand to the parser. tempfiles, not pipes, since we need both
# streams plus the exit status.
tracker_stdout=$(mktemp "$CACHE_DIR/tracker.stdout.XXXXXX")
tracker_stderr=$(mktemp "$CACHE_DIR/tracker.stderr.XXXXXX")
tracker_exit=0
( cd "$PROJECT_DIR" && \
  roadmap_tracker_issue_list --label next-up --state open --limit 1 \
     --json number,title,url,body,labels,updatedAt \
     >"$tracker_stdout" 2>"$tracker_stderr" ) || tracker_exit=$?

if [ "$tracker_exit" -ne 0 ]; then
  tracker_err=$(cat "$tracker_stderr" 2>/dev/null || true)
  rm -f "$tracker_stdout" "$tracker_stderr"
  # Distinguish "not a GitHub repo" from other default-adapter failures.
  if [ "$ROADMAP_BACKEND" = "github" ] \
     && printf '%s' "$tracker_err" | grep -qiE 'no.*github.*remote|not a github repository'; then
    write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": true,
  "error": null,
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)")"
    exit 0
  fi
  tracker_call_error="tracker-call-failed"
  case "$ROADMAP_BACKEND" in
    github) tracker_call_error="gh-call-failed" ;;
    azure-devops) tracker_call_error="azure-devops-call-failed" ;;
  esac
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": "%s",
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)" "$tracker_call_error")"
  write_err "tracker issue list call failed: $tracker_err"
  exit 2
fi

issues_json=$(cat "$tracker_stdout")
rm -f "$tracker_stdout" "$tracker_stderr"

# If the array is empty, no OPEN issue carries the label.
# F1: Closed next-up probe — the real auto-advance trigger. The open fetch
# returned [] because the next-up issue is now CLOSED (was just merged/closed).
# Check for a recently-closed next-up and, if found, run the epic resolver to
# see if there is an auto-advance candidate (ready sibling in the same epic).
if [ -z "$issues_json" ] || [ "$issues_json" = "[]" ]; then
  # Probe for a CLOSED issue carrying the next-up label
  _closed_stdout=$(mktemp "$CACHE_DIR/tracker.closed.XXXXXX")
  _closed_exit=0
  ( cd "$PROJECT_DIR" && \
    roadmap_tracker_issue_list --label next-up --state closed --limit 1 \
      --json number \
      >"$_closed_stdout" 2>/dev/null ) || _closed_exit=$?
  _closed_num=""
  if [ "$_closed_exit" -eq 0 ]; then
    _closed_num=$(python3 -c \
      'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["number"] if d else "")' \
      "$_closed_stdout" 2>/dev/null || true)
  fi
  rm -f "$_closed_stdout"

  if [ -n "$_closed_num" ] && command -v python3 >/dev/null 2>&1; then
    # Found a closed next-up — try epic-walk for auto-advance.
    # The helper writes the cache only when auto-advance fires; use a sentinel
    # stamp to detect whether it ran (we use the cache mtime vs a pre-call stamp).
    _pre_call_stamp=$(mktemp "$CACHE_DIR/stamp.XXXXXX")
    run_epic_walk_and_cache_if_advance "$_closed_num"
    # If the helper did NOT find an advance (returned without writing cache),
    # write the standard empty cache. We detect "no write" by checking if
    # CACHE_FILE is newer than our pre-call stamp — if not, the helper did
    # nothing (or python was unavailable).
    _cache_was_written=false
    if [ -f "$CACHE_FILE" ] && [ "$CACHE_FILE" -nt "$_pre_call_stamp" ]; then
      _cache_was_written=true
    fi
    rm -f "$_pre_call_stamp"
    if ! $_cache_was_written; then
      write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": null,
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)")"
    fi
  else
    # No closed next-up found (or python3 unavailable) — standard empty cache
    write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": null,
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)")"
  fi
  exit 0
fi

# ── Fetch handoff comments for the next-up issue ─────────────────────
# A second tracker call: the latest `arbo-handoff`-marked comment on the
# next-up issue is the current session-handoff note (design §4.6).
issue_number=$(printf '%s' "$issues_json" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")' 2>/dev/null || true)
comments_file=$(mktemp "$CACHE_DIR/tracker.comments.XXXXXX")
echo '{"comments":[]}' > "$comments_file"
# Distinguish "tracker issue show succeeded with no comments" from "tracker fetch
# failed" — pre-#264 these collapsed into the same silent-empty state, which
# made handoff: null indistinguishable from a transient fetch failure. Now we
# propagate the distinction via env vars to the python3 cache-builder below
# (refresh-next-cache.contract.md RNC-4 pins this as non-recurrable).
comment_fetch_status="not-attempted"
comment_fetch_err=""
if [ -n "$issue_number" ]; then
  comment_stderr=$(mktemp "$CACHE_DIR/tracker.comments.err.XXXXXX")
  if ( cd "$PROJECT_DIR" && roadmap_tracker_issue_show "$issue_number" --json comments ) \
       > "$comments_file" 2>"$comment_stderr"; then
    comment_fetch_status="ok"
  else
    comment_fetch_status="failed"
    # Two separate capture variables — the cache JSON gets only the first
    # line of stderr (keeps cache readable per design D7/OQ2); the diagnostic
    # file gets the FULL multi-line stderr (preserved for debugging). Codex
    # caught the conflation in PR #365 review — using only $comment_fetch_err
    # for both would truncate multi-line tracker diagnostics in the .err file too.
    comment_fetch_err=$(head -1 "$comment_stderr" 2>/dev/null || true)
    # Keep the comments file valid JSON even though the builder won't read it
    # in the failure path — defense in depth against a future refactor that
    # might call latest_handoff() without first checking COMMENT_FETCH_STATUS.
    echo '{"comments":[]}' > "$comments_file"
    # Emit each stderr line through write_err so every line gets a timestamp
    # prefix — write_err is a single-line logger (`printf '[%s] %s\n' ...`),
    # so a multi-line argument would prefix only the first line. Per Copilot
    # PR #368 review.
    write_err "tracker issue comments call failed:"
    while IFS= read -r _err_line; do
      [ -n "$_err_line" ] && write_err "  $_err_line"
    done < "$comment_stderr"
  fi
  rm -f "$comment_stderr"
fi

# ── Truncate body and emit cache ─────────────────────────────────────

# ── Epic-aware orientation (issue #562) ──────────────────────────────
# Call the epic resolver to get epics_in_flight + auto_advance candidate.
# Fail-soft: any failure (script missing, live fetch error, python error)
# degrades to the empty shape. Never changes the script's exit code.
#
# F4(b): run epic-walk.sh under PROJECT_DIR so roadmap_github_epic_graph's
# `gh repo view` resolves to the correct repository context.
epic_json='{"epics_in_flight":[],"auto_advance":null}'
if [ -f "$SCRIPT_DIR/roadmap/epic-walk.sh" ]; then
  if epic_out=$( cd "$PROJECT_DIR" && bash "$SCRIPT_DIR/roadmap/epic-walk.sh" --next-up "${issue_number:-}" 2>>"$ERR_FILE" ); then
    [ -n "$epic_out" ] && epic_json="$epic_out"
  else
    write_err "epic-walk failed; epics_in_flight omitted from cache"
  fi
fi
epic_file=$(mktemp "$CACHE_DIR/epic.json.XXXXXX")
printf '%s' "$epic_json" > "$epic_file"

# Use python3 if available for robust JSON shaping; otherwise fall back
# to a jq-and-awk pipeline. The python3 path is the common case in CI
# and on developer machines.

if command -v python3 >/dev/null 2>&1; then
  # Pass issues_json via a temp file rather than argv to avoid OS
  # arg-length limits on issues with very long bodies.
  issues_file=$(mktemp "$CACHE_DIR/tracker.issues.XXXXXX")
  printf '%s' "$issues_json" > "$issues_file"
  cache_json=$(FETCHED_AT="$(now_iso)" \
               COMMENT_FETCH_STATUS="$comment_fetch_status" \
               COMMENT_FETCH_ERR="$comment_fetch_err" \
               python3 - "$issues_file" "$comments_file" "$epic_file" <<'PY'
import json, os, re, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
issue = data[0] if data else None

# Strip ASCII control characters (including \x1b ANSI escape
# introducers) from any string we write into the cache. Issue
# titles/bodies are author-controlled tracker content, and the
# session-start banner pipes them straight to a terminal — without
# this scrub, a malicious issue could inject ANSI escapes that
# manipulate display/logs.
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

def truncate(body):
    """First non-empty paragraph after any leading H1/H2, capped at
    5 lines / 400 chars total. Each line is control-char-scrubbed."""
    if not body:
        return []
    lines = body.replace("\r\n", "\n").split("\n")
    out, total = [], 0
    in_body = False
    for raw in lines:
        line = scrub(raw.rstrip())
        # Skip leading H1/H2 if present at the very top.
        if not in_body and line.startswith(("# ", "## ")):
            continue
        if not in_body and line.strip() == "":
            continue
        in_body = True
        if line.strip() == "" and out:
            break
        if line.strip() == "":
            continue
        # Skip HTML comments
        if line.lstrip().startswith("<!--"):
            continue
        if total + len(line) > 400:
            line = line[: 400 - total] + "..."
            out.append(line)
            break
        out.append(line)
        total += len(line)
        if len(out) >= 5:
            break
    return out

def latest_handoff(comments_path):
    """The newest comment whose body starts with the arbo-handoff
    marker. Returns a {posted_at, branch, next_action, body} dict or
    None. design §4.1/§4.6."""
    try:
        with open(comments_path, encoding="utf-8") as fh:
            comments = (json.load(fh) or {}).get("comments", []) or []
    except Exception:
        return None
    marked = [c for c in comments
              if isinstance(c, dict)
              and isinstance(c.get("body"), str)
              and c["body"].lstrip().startswith("<!-- arbo-handoff:")]
    if not marked:
        return None
    marked.sort(key=lambda c: c.get("createdAt", ""))
    c = marked[-1]
    body = c["body"]
    m = re.search(r"<!--\s*arbo-handoff:\s*(\S+)\s+(\S+)\s*-->", body)
    branch = scrub(m.group(1)) if m else ""
    posted = scrub(m.group(2)) if m else c.get("createdAt", "")
    note_lines = [ln for ln in body.splitlines()
                  if not ln.lstrip().startswith("<!-- arbo-handoff:")
                  and not ln.startswith("**Session handoff**")]
    note = "\n".join(note_lines).strip()
    next_action = ""
    for ln in note.splitlines():
        if ln.strip().startswith("→ Next action:"):
            next_action = scrub(ln.strip()[len("→ Next action:"):].strip())
            break
    prose, started = [], False
    for ln in note.splitlines():
        if ln.strip().startswith("→ Next action:"):
            started = True
            continue
        if not started:
            continue
        if ln.strip() == "" and prose:
            break
        if ln.strip():
            prose.append(scrub(ln.rstrip()))
    return {
        "posted_at": posted,
        "branch": branch,
        "next_action": next_action,
        "body": " ".join(prose),
    }

# Branch on COMMENT_FETCH_STATUS (propagated from the shell layer):
#   "failed"        — tracker issue show exited non-zero; emit the error union variant
#   "ok"            — tracker issue show succeeded; latest_handoff() returns the
#                     handoff dict (or None for genuine no-handoff)
#   "not-attempted" — issue_number couldn't be parsed (rare path); fall through
#                     to latest_handoff() on the seeded empty comments file
# Per refresh-next-cache.contract.md RNC-3 + RNC-4 + design D2.
comment_status = os.environ.get("COMMENT_FETCH_STATUS", "ok")
comment_err = os.environ.get("COMMENT_FETCH_ERR", "")
if comment_status == "failed":
    handoff = {
        "error": "fetch-failed",
        "detail": scrub(comment_err),  # RNC-6 ANSI-scrub invariant
    }
else:
    handoff = latest_handoff(sys.argv[2])

# ── Merge epics_in_flight + auto_advanced (issue #562) ───────────────
# Load the resolver output from the temp file. Titles are already scrubbed
# by epic-walk.sh; apply scrub() defensively here (belt-and-suspenders per
# CLAUDE.md defense-in-depth) in case a hand-edited or old-format file
# bypasses the resolver's own scrub pass.
def scrub_epic(e):
    """Deep-scrub all author-controlled string fields in one epic entry."""
    out = dict(e)
    out["title"] = scrub(out.get("title", ""))
    out["active"] = [
        {**c, "title": scrub(c.get("title", "")), "stage": c.get("stage")}
        for c in (out.get("active") or [])
    ]
    if out.get("next"):
        out["next"] = {**out["next"], "title": scrub(out["next"].get("title", ""))}
    out["blocked"] = [
        {**b, "title": scrub(b.get("title", ""))}
        for b in (out.get("blocked") or [])
    ]
    return out

try:
    with open(sys.argv[3], encoding="utf-8") as fh:
        epic_data = json.load(fh)
    epics_in_flight = [scrub_epic(e) for e in epic_data.get("epics_in_flight", [])]
    # auto_advanced is set ONLY when the label write succeeds (see shell below).
    # The python builder always stores what the resolver returned here; the shell
    # layer below decides whether to overwrite it with null (if write failed) or
    # keep it (if write succeeded). Both branches keep the cache shape stable.
    auto_advance_candidate = epic_data.get("auto_advance")
except Exception:
    epics_in_flight = []
    auto_advance_candidate = None

if issue is None:
    cache = {
        "fetched_at": os.environ["FETCHED_AT"],
        "issue": None,
        "handoff": handoff,
        "no_gh_remote": False,
        "error": None,
        "epics_in_flight": epics_in_flight,
        "auto_advanced": auto_advance_candidate,
    }
else:
    body = issue.get("body") or ""
    cache = {
        "fetched_at": os.environ["FETCHED_AT"],
        "issue": {
            "number": issue["number"],
            "title": scrub(issue["title"]),
            "url": issue["url"],
            "body_first_lines": truncate(body),
            "body_empty": len(body.strip()) == 0,
            "labels": [l["name"] for l in issue.get("labels", [])],
            "updated_at": issue.get("updatedAt", ""),
        },
        "handoff": handoff,
        "no_gh_remote": False,
        "error": None,
        "epics_in_flight": epics_in_flight,
        "auto_advanced": auto_advance_candidate,
    }
print(json.dumps(cache, indent=2))
PY
)
  rm -f "$issues_file" "$comments_file"

  # Write the cache now — the auto-advance block below may need to rewrite it.
  write_cache "$cache_json"

  # ── One-shot auto-advance label write (fail-soft) ────────────────────
  # Design: `auto_advanced` is only set in the cache for the run that actually
  # performs the label move. The resolver returns `auto_advance` only when the
  # current next-up is CLOSED and its epic has a ready sibling. Once the label
  # moves to the new issue, the next boot's next-up will be the open child —
  # epic-walk then returns auto_advance:null naturally, guaranteeing one-shot
  # behavior without any external state management.
  #
  # Concretely: we write the cache above with auto_advanced = the resolver's
  # candidate. If the label write SUCCEEDS, the cache stands as-is (one boot
  # will show the ⤴ banner). If the write FAILS, we rewrite the cache with
  # auto_advanced:null (the banner never fires). Either way the label write
  # is never retried: the next run sees a different next-up (open child) or
  # the same closed next-up with no change in epic state.
  auto_to=$(printf '%s' "$epic_json" | python3 -c \
    'import json,sys;a=json.load(sys.stdin)["auto_advance"];print(a["to"] if a else "")' \
    2>/dev/null || true)
  auto_from=$(printf '%s' "$epic_json" | python3 -c \
    'import json,sys;a=json.load(sys.stdin)["auto_advance"];print(a["from"] if a else "")' \
    2>/dev/null || true)
  if [ -n "$auto_to" ] && [ -n "$auto_from" ]; then
    # F2: add-to-target FIRST, then remove-from-source.
    # If add fails → don't remove (source keeps next-up; treat as failure).
    # If add succeeds but remove fails → tolerable transient (two labels; open-
    # fetch --limit 1 picks one); treat the advance as succeeded.
    _advance_ok=false
    if ( cd "$PROJECT_DIR" && roadmap_tracker_issue_update "$auto_to" --add-label next-up ) 2>>"$ERR_FILE"; then
      _advance_ok=true
      # add succeeded — now remove from source (tolerate failure)
      if ! ( cd "$PROJECT_DIR" && roadmap_tracker_issue_update "$auto_from" --remove-label next-up ) 2>>"$ERR_FILE"; then
        write_err "auto-advance: --add-label next-up on #${auto_to} succeeded but --remove-label from #${auto_from} failed (tolerable transient — two issues carry next-up label; next open-fetch resolves)"
      fi
    else
      write_err "auto-advance label write failed: --add-label next-up on #${auto_to} failed; next-up label stays on #${auto_from}"
    fi

    if ! $_advance_ok; then
      # add failed — banner must not fire; rewrite cache with auto_advanced:null
      write_err "auto-advance label write failed (#${auto_from}->#${auto_to}); banner renders read-only"
      # Rewrite cache with auto_advanced:null — the move didn't happen so
      # the ⤴ banner must not fire (user would see a lie).
      # Capture into a temp var; only write_cache if non-empty so a python
      # failure does not truncate the existing cache file.
      _rewrite_json=$(python3 - "$CACHE_FILE" 2>/dev/null <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c['auto_advanced'] = None
print(json.dumps(c, indent=2))
PY
)
      if [ -n "$_rewrite_json" ]; then
        cache_json="$_rewrite_json"
        write_cache "$cache_json"
      else
        write_err "auto-advance rewrite produced empty output; leaving existing cache untouched"
      fi
    fi
  fi
else
  # Minimal fallback without python3 — do NOT attempt to hand-build
  # JSON from issue fields, because shell string interpolation will
  # not correctly escape arbitrary JSON content (a title containing
  # a quote, backslash, or newline would emit invalid JSON, which
  # the hook's reader would silently skip). Emit a minimal cache
  # shape with issue: null and a descriptive error so the file is
  # always valid JSON on minimal systems and the user gets a
  # diagnostic pointing at the missing prerequisite.
  cache_json=$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": "python3 unavailable; issue details omitted in fallback cache",
  "epics_in_flight": [],
  "auto_advanced": null
}' "$(now_iso)")
  rm -f "$comments_file"
  write_err "python3 not found — issue details omitted from cache. Install python3 to surface next-up details in the boot banner."
  # python3-absent path: write the fallback cache here (python3 path writes above).
  write_cache "$cache_json"
fi

rm -f "$epic_file"
exit 0
