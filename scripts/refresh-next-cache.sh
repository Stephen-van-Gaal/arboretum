#!/usr/bin/env bash
# owner: project-infrastructure
# refresh-next-cache.sh — Refresh .arboretum/next-cache.json from GitHub.
#
# Reads the open issue carrying the `next-up` label (at most one) via
# `gh` and writes a small JSON cache that `session-start.sh` consumes.
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
#     "no_gh_remote": true | false,
#     "error": null | "gh-unavailable" | "gh-call-failed"
#                  | "python3 unavailable; issue details omitted in fallback cache"
#   }
#
# Title and body lines are stripped of ASCII control characters
# (including \x1b ANSI escape introducers) when stored, so the
# session-start banner can render them as-is without risk of
# remote-controlled terminal-escape injection (issue text is
# author-controlled on GitHub).
#
# Usage:
#   bash scripts/refresh-next-cache.sh [project-dir]
#
# Exit codes:
#   0  — cache written (issue found, no issue, or no GH remote)
#   1  — gh CLI missing or unauthenticated (cache also reflects this)
#   2  — gh call failed for some other reason
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

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/next-cache.json"
ERR_FILE="$CACHE_DIR/next-cache.err"

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
# We don't insist the URL contain github.com — the cloud Claude env
# proxies via a local URL, and self-hosted GHE installs use custom
# domains. We also don't insist on a remote named `origin` — repos
# that use `upstream`-style workflows would be silently skipped.
# Any remote is good enough; gh decides whether it's actually a GH
# repo when called.

remote_name=$(git -C "$PROJECT_DIR" remote 2>/dev/null | head -n 1 || true)
if [ -z "$remote_name" ]; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": true,
  "error": null
}' "$(now_iso)")"
  exit 0
fi

# ── Detect gh ────────────────────────────────────────────────────────

if ! command -v gh >/dev/null 2>&1; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": false,
  "error": "gh-unavailable"
}' "$(now_iso)")"
  write_err "gh CLI not found on PATH"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": false,
  "error": "gh-unavailable"
}' "$(now_iso)")"
  write_err "gh CLI is installed but not authenticated (run: gh auth login)"
  exit 1
fi

# ── Fetch the next-up issue ──────────────────────────────────────────
# Run gh from inside the project dir so it picks up the right repo
# from the local git config; no need to pass -R explicitly.

# Capture stdout (the JSON payload) and stderr (warnings/errors)
# separately, so a stderr warning from gh doesn't poison the JSON
# we hand to the parser. tempfiles, not pipes, since we need both
# streams plus the exit status.
gh_stdout=$(mktemp "$CACHE_DIR/gh.stdout.XXXXXX")
gh_stderr=$(mktemp "$CACHE_DIR/gh.stderr.XXXXXX")
gh_exit=0
( cd "$PROJECT_DIR" && \
  gh issue list --label next-up --state open --limit 1 \
     --json number,title,url,body,labels,updatedAt \
     >"$gh_stdout" 2>"$gh_stderr" ) || gh_exit=$?

if [ "$gh_exit" -ne 0 ]; then
  gh_err=$(cat "$gh_stderr" 2>/dev/null || true)
  rm -f "$gh_stdout" "$gh_stderr"
  # Distinguish "not a GH repo" from other failures.
  if printf '%s' "$gh_err" | grep -qiE 'no.*github.*remote|not a github repository'; then
    write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": true,
  "error": null
}' "$(now_iso)")"
    exit 0
  fi
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": false,
  "error": "gh-call-failed"
}' "$(now_iso)")"
  write_err "gh issue list call failed: $gh_err"
  exit 2
fi

issues_json=$(cat "$gh_stdout")
rm -f "$gh_stdout" "$gh_stderr"

# If the array is empty, no issue carries the label.
if [ -z "$issues_json" ] || [ "$issues_json" = "[]" ]; then
  write_cache "$(printf '{
  "fetched_at": "%s",
  "issue": null,
  "no_gh_remote": false,
  "error": null
}' "$(now_iso)")"
  exit 0
fi

# ── Truncate body and emit cache ─────────────────────────────────────

# Use python3 if available for robust JSON shaping; otherwise fall back
# to a jq-and-awk pipeline. The python3 path is the common case in CI
# and on developer machines.

if command -v python3 >/dev/null 2>&1; then
  # Pass issues_json via a temp file rather than argv to avoid OS
  # arg-length limits on issues with very long bodies.
  issues_file=$(mktemp "$CACHE_DIR/gh.issues.XXXXXX")
  printf '%s' "$issues_json" > "$issues_file"
  cache_json=$(FETCHED_AT="$(now_iso)" python3 - "$issues_file" <<'PY'
import json, os, re, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
issue = data[0] if data else None

# Strip ASCII control characters (including \x1b ANSI escape
# introducers) from any string we write into the cache. Issue
# titles/bodies are author-controlled on GitHub, and the
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

if issue is None:
    cache = {
        "fetched_at": os.environ["FETCHED_AT"],
        "issue": None,
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
        "no_gh_remote": False,
        "error": None,
    }
print(json.dumps(cache, indent=2))
PY
)
  rm -f "$issues_file"
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
  "no_gh_remote": false,
  "error": "python3 unavailable; issue details omitted in fallback cache"
}' "$(now_iso)")
  write_err "python3 not found — issue details omitted from cache. Install python3 to surface next-up details in the boot banner."
fi

write_cache "$cache_json"
exit 0
