#!/usr/bin/env bash
# owner: pipeline-state-tracking
# refresh-stage-cache.sh — Populate .arboretum/active-stage-cache.json
# from the active issue's exclusive stage:* label (#570). See WS9 design D6.
#
# Active-issue resolution:
#   1. Current branch name matches `<prefix>/<slug>` where a design spec
#      docs/superpowers/specs/*-<slug>-design.md has `related-issue: <N>`
#      in frontmatter → use issue N. Also accepts `<prefix>/<slug>-build`
#      (the build-branch convention).
#   2. Else if a `next-up`-labeled open tracker item exists → use it.
#   3. Else issue:null.
#
# Cache shape:
#   { "issue": <int>|null, "stage": "<name>"|null,
#     "title": "<string, control-char-stripped>"|null, "ts": "<ISO-8601 UTC>" }
#   (#763: `title` is the active issue's title, surfaced on the user-only
#    statusline — never the model-facing SessionStart banner.)
#
# Usage: bash scripts/refresh-stage-cache.sh [project-dir]
# Exit:  0 always (cache reflects errors via stage:null or issue:null).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/active-stage-cache.json"
mkdir -p "$CACHE_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/scrub-control-chars.sh"
# shellcheck source=roadmap/lib.sh
source "$SCRIPT_DIR/roadmap/lib.sh"
export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_DIR")}"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

write_cache() {
  # Atomic rename via mktemp so racing refreshes never clobber each other.
  local tmp
  tmp=$(mktemp "$CACHE_DIR/active-stage-cache.json.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

emit_null() {
  write_cache "$(printf '{"issue": null, "stage": null, "title": null, "ts": "%s"}' "$(now_iso)")"
}

roadmap_probe_backend_access "$ROADMAP_BACKEND" "$PROJECT_DIR" >/dev/null 2>&1 || { emit_null; exit 0; }
# python3 is required for JSON shaping; without it the python3 -c calls
# below would die under set -euo pipefail. Match the header's "Exit: 0
# always" contract by degrading gracefully to a null cache.
command -v python3 >/dev/null 2>&1 || { emit_null; exit 0; }

# ── Step 1: branch-based resolution ──────────────────────────────────
branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# Strip the prefix (feat/, fix/, etc.).
slug="${branch#*/}"
# Strip trailing -build suffix if present (so feat/foo-build matches foo-design.md).
slug_no_build="${slug%-build}"

issue=""
for cand in "$slug" "$slug_no_build"; do
  [ -z "$cand" ] && continue
  spec=$(ls "$PROJECT_DIR"/docs/superpowers/specs/*-"$cand"-design.md 2>/dev/null | head -1 || true)
  if [ -n "$spec" ]; then
    issue=$(grep -E '^related-issue:[[:space:]]*[0-9]+' "$spec" | head -1 \
            | sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/')
    [ -n "$issue" ] && break
  fi
done

# ── Step 2: next-up fallback ─────────────────────────────────────────
if [ -z "$issue" ]; then
  next_json=$( cd "$PROJECT_DIR" && roadmap_tracker_issue_list --label next-up --state open --limit 1 --json number 2>/dev/null || echo "[]" )
  issue=$(python3 -c '
import json, sys
data = json.loads(sys.stdin.read() or "[]")
# Tracker issue list returns an array; stubs may return the same shape.
if isinstance(data, list):
    print(data[0]["number"] if data else "")
else:
    print("")
' <<<"$next_json")
fi

if [ -z "$issue" ]; then
  emit_null
  exit 0
fi

# ── Step 3: read labels + title in ONE tracker call ──────────────────
# Stage lives as an exclusive `stage:<name>` label/tag (#570). Restore the
# leading slash dropped at write time (stage:design -> /design). The value
# is still scrubbed of control characters (belt-and-braces; label names are
# constrained but the scrub matches the defense-in-depth pattern).
#
# #763/#767: the active issue's `title` is fetched for the statusline (a
# user-only display surface — the model never ingests it, so rendering the
# author-controlled title there is injection-safe; the SessionStart banner
# renders only the bare issue number). Labels + title are fetched in a SINGLE
# `roadmap_tracker_issue_show --json labels,title` call (no `--jq`) — folding
# the title into the existing labels call avoids a second tracker round-trip on
# this 30s-TTL background refresh (Copilot review on PR #767). Both are parsed
# from the JSON payload below.
issue_json=$( cd "$PROJECT_DIR" && roadmap_tracker_issue_show "$issue" --json labels,title 2>/dev/null || echo '{}' )

# Serialize via python3 (not printf) so a stage/title value containing `"`
# or `\` cannot break the JSON shape — printf '%s' just interpolates,
# leaving downstream `json.load` consumers (statusline.sh + session-
# start.sh) to silently lose pipeline-state rendering on a malformed
# cache file. (Codex R2-1.)
cache_json=$(ISSUE_JSON="$issue_json" ISSUE="$issue" TS="$(now_iso)" python3 -c '
import json, os, re
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s): return _CTRL.sub("", s) if isinstance(s, str) else s
try:
    d = json.loads(os.environ.get("ISSUE_JSON") or "{}")
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
stage = None
for lab in d.get("labels") or []:
    name = lab.get("name", "") if isinstance(lab, dict) else str(lab)
    if name.startswith("stage:"):
        stage = scrub("/" + name[len("stage:"):])
        break
title = scrub((d.get("title") or "").strip()) or None
print(json.dumps({"issue": int(os.environ["ISSUE"]), "stage": stage, "title": title, "ts": os.environ["TS"]}))
')
write_cache "$cache_json"

# ── Step 4: fetch log comments for the active issue (D7) ─────────────
# Filtered to comments carrying the <!-- pipeline-state:log --> marker.
# Used by .claude/hooks/session-start.sh's pipeline-state block.
LOG_CACHE_FILE="$CACHE_DIR/log-comments-cache.json"
comments_raw=$( cd "$PROJECT_DIR" && roadmap_tracker_issue_comments "$issue" --paginate 2>/dev/null || echo "[]" )
filtered=$(python3 -c '
import json, os, re, sys
# Same defense-in-depth scrub as Step 3: comment bodies are author-
# controlled and feed the boot banner — strip ASCII control chars to
# block ANSI-escape injection from the source.
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

# Some tracker adapters concatenate paginated page bodies — for JSON arrays this
# means multiple `[...]` documents back-to-back, NOT a single array.
# `json.loads(raw)` chokes with "Extra data" on the second page; the
# original `except: data = []` would have silently swallowed the
# error and emitted an empty cache for any item with >30 comments
# (GitHub default page size). Use raw_decode to walk the documents
# one at a time and concatenate the arrays. (Codex R2-2.)
raw = sys.stdin.read().strip() or "[]"
data = []
decoder = json.JSONDecoder()
idx = 0
while idx < len(raw):
    # Skip whitespace between documents.
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    try:
        obj, end = decoder.raw_decode(raw, idx)
    except json.JSONDecodeError:
        # Malformed page — stop here rather than silently dropping all
        # data from previous pages.
        break
    if isinstance(obj, list):
        data.extend(obj)
    elif isinstance(obj, dict):
        data.append(obj)
    idx = end
out = []
for c in data:
    body = c.get("body", "") or ""
    if "<!-- pipeline-state:log -->" in body:
        out.append({
            "body": scrub(body),
            "createdAt": scrub(c.get("created_at") or c.get("createdAt", "")),
        })
print(json.dumps(out))
' <<<"$comments_raw")

# Atomic rename for the log cache too.
tmp=$(mktemp "$CACHE_DIR/log-comments-cache.json.XXXXXX")
printf '%s\n' "$filtered" > "$tmp"
mv "$tmp" "$LOG_CACHE_FILE"

exit 0
