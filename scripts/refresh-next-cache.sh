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
  "error": null
}' "$(now_iso)")"
  exit 0
fi

# ── Detect tracker backend ───────────────────────────────────────────

backend_stderr=$(mktemp "$CACHE_DIR/backend.stderr.XXXXXX")
if ! roadmap_require_backend "$ROADMAP_BACKEND" > /dev/null 2>"$backend_stderr"; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": "gh-unavailable"
}' "$(now_iso)")"
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
  if printf '%s' "$tracker_err" | grep -qiE 'no.*github.*remote|not a github repository'; then
    write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": true,
  "error": null
}' "$(now_iso)")"
    exit 0
  fi
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": "gh-call-failed"
}' "$(now_iso)")"
  write_err "tracker issue list call failed: $tracker_err"
  exit 2
fi

issues_json=$(cat "$tracker_stdout")
rm -f "$tracker_stdout" "$tracker_stderr"

# If the array is empty, no issue carries the label.
if [ -z "$issues_json" ] || [ "$issues_json" = "[]" ]; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "handoff": null,
  "no_gh_remote": false,
  "error": null
}' "$(now_iso)")"
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
               python3 - "$issues_file" "$comments_file" <<'PY'
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

if issue is None:
    cache = {
        "fetched_at": os.environ["FETCHED_AT"],
        "issue": None,
        "handoff": handoff,
        "no_gh_remote": False,
        "error": None,
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
    }
print(json.dumps(cache, indent=2))
PY
)
  rm -f "$issues_file" "$comments_file"
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
  "error": "python3 unavailable; issue details omitted in fallback cache"
}' "$(now_iso)")
  rm -f "$comments_file"
  write_err "python3 not found — issue details omitted from cache. Install python3 to surface next-up details in the boot banner."
fi

write_cache "$cache_json"
exit 0
