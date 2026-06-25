#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# read-journey-log.sh — Read journey-log entries written by log-stage.sh
# from a GitHub issue's comments. Emits TSV (one row per entry) so other
# scripts and skills can consume the structured stream without re-parsing
# the line format.
#
# See docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws9-state-tracking-design.md
# for the producer-side definition of the line format.
#
# Usage:
#   bash scripts/read-journey-log.sh <issue-number> [--stage <name>] [--action <name>] [--latest]
#
# Output (TSV):
#   <timestamp>\t<stage>\t<action>\t<key>=<value>\t<key>=<value>...
#
# Exit codes:
#   0 — success (zero or more rows emitted)
#   1 — bad args / gh missing / unauthenticated
#   2 — fetch failed
set -euo pipefail
[ -n "${BASH_SOURCE[0]:-}" ] && [ -n "${BASH_VERSION:-}" ] || { echo "read-journey-log.sh requires bash" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: read-journey-log.sh <issue-number> [--stage <name>] [--action <name>] [--latest]
EOF
  exit 1
}

[ "$#" -ge 1 ] || usage
ISSUE="$1"; shift

STAGE_FILTER=""
ACTION_FILTER=""
LATEST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage)  [ "${2+set}" = "set" ] || { echo "read-journey-log.sh: --stage requires a value" >&2; usage; }
              STAGE_FILTER="$2"; shift 2 ;;
    --action) [ "${2+set}" = "set" ] || { echo "read-journey-log.sh: --action requires a value" >&2; usage; }
              ACTION_FILTER="$2"; shift 2 ;;
    --latest) LATEST=1; shift ;;
    *) echo "read-journey-log.sh: unknown arg: $1" >&2; usage ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "read-journey-log.sh requires the gh CLI" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/scrub-control-chars.sh"

# Resolve the journey-log author allowlist (#249). TRUST_CONFIG_OVERRIDE lets
# tests point at a fixture config; production resolves .arboretum.yml at the
# git toplevel. Key present → strict (only allowlisted authors surface); key
# absent → permissive migration bridge (all authors surface + one warning).
# Resolve the config path safely: prefer the override, then the git toplevel.
# Outside a git worktree with no override, there is no config to resolve.
TRUST_CONFIG=""
if [ -n "${TRUST_CONFIG_OVERRIDE:-}" ]; then
  TRUST_CONFIG="$TRUST_CONFIG_OVERRIDE"
else
  _toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_toplevel" ] && TRUST_CONFIG="$_toplevel/.arboretum.yml"
fi
TRUST_PRESENT="no"
ALLOWLIST=""
if [ -n "$TRUST_CONFIG" ] && [ -f "$TRUST_CONFIG" ]; then
  # Fail CLOSED on a parse error: when the config exists but the reader fails
  # (e.g. invalid YAML-lite from a manual edit), do NOT silently widen the trust
  # boundary to permissive — propagate the failure (#249 review, Copilot+Codex).
  if ! trust_out="$(bash "$SCRIPT_DIR/read-trust-config.sh" "$TRUST_CONFIG" 2>&1)"; then
    echo "read-journey-log.sh: trust config $TRUST_CONFIG exists but could not be parsed — refusing to fall back to permissive mode (#249):" >&2
    printf '%s\n' "$trust_out" >&2
    exit 1
  fi
  if printf '%s\n' "$trust_out" | grep -qx 'present=yes'; then
    TRUST_PRESENT="yes"
  fi
  ALLOWLIST="$(printf '%s\n' "$trust_out" | sed -n 's/^author=//p')"
fi
if [ "$TRUST_PRESENT" = "no" ]; then
  echo "read-journey-log.sh: trust.journey_log_authors not configured — surfacing journey-log entries from ALL comment authors; see #249" >&2
fi

# Determine owner/repo from the current directory's git remote.
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || {
  echo "read-journey-log.sh: could not determine repo (run inside a gh-authenticated repo)" >&2
  exit 1
}

# Fetch all comments into a temp file, then parse with python3.
# (Piping directly to `python3 - <<'PY'` conflicts: the heredoc occupies
# stdin for the script body, leaving the pipe data with no reader.)
#
# `gh api --paginate` concatenates per-page JSON arrays back-to-back
# (not a single merged array). Without `--slurp`, a single json.load
# fails with "Extra data" on multi-page histories. We use raw_decode
# in the parser to handle both cases (single-page and concatenated).
_TMPJSON=$(mktemp) || { echo "read-journey-log.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$_TMPJSON"' EXIT
gh api "repos/$REPO/issues/$ISSUE/comments" --paginate 2>/dev/null \
  > "$_TMPJSON" || { echo "read-journey-log.sh: gh api fetch failed" >&2; exit 2; }

RJL_ALLOWLIST="$ALLOWLIST" RJL_TRUST_PRESENT="$TRUST_PRESENT" \
python3 - "$_TMPJSON" "$STAGE_FILTER" "$ACTION_FILTER" "$LATEST" <<'PY'
import json, os, re, sys
comments_file, stage_filter, action_filter, latest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

# Author-trust filter (#249): in strict mode (allowlist key present) only
# allowlisted comment authors contribute rows. Untrusted authors are silently
# ignored — NOT an error (they may be legitimate contributor notes).
_allow = set(l for l in os.environ.get("RJL_ALLOWLIST", "").split("\n") if l)
_trust_present = os.environ.get("RJL_TRUST_PRESENT", "no") == "yes"

# Read-side control-char scrub at the consumer boundary (pipeline-state-tracking
# spec § Defense in depth). Same regex as scripts/refresh-next-cache.sh.
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

# Handle gh api --paginate output: it concatenates page bodies (multiple
# JSON arrays back-to-back). raw_decode consumes one JSON value at a time
# from the start of the remaining buffer, so we loop until exhausted.
def load_paginated(path):
    with open(path) as f:
        text = f.read().lstrip()
    dec = json.JSONDecoder()
    items = []
    pos = 0
    n = len(text)
    while pos < n:
        # Skip whitespace between concatenated documents.
        while pos < n and text[pos].isspace():
            pos += 1
        if pos >= n:
            break
        obj, end = dec.raw_decode(text, pos)
        if isinstance(obj, list):
            items.extend(obj)
        else:
            items.append(obj)
        pos = end
    return items

data = load_paginated(comments_file)

# Single-pass left-to-right unescape — chained .replace() corrupts
# overlapping escapes (e.g. literal `\\n` encoded as `\\\\n` mis-decodes).
# Keeps `\n` encoded as the two-char sequence rather than decoding to a
# real newline, so the TSV "one row per entry" guarantee is preserved
# even if a logged value contained a literal newline.
def unescape(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '\\' and i + 1 < n:
            nxt = s[i + 1]
            if nxt == '\\':
                out.append('\\')
                i += 2
                continue
            if nxt == '"':
                out.append('"')
                i += 2
                continue
            # Note: \n is left as the two-char escape so TSV stays line-safe.
        out.append(c)
        i += 1
    return ''.join(out)

MARKER = "<!-- pipeline-state:log -->"
LINE_RE = re.compile(
    r"^- (?P<ts>\S+) — (?P<stage>\S+) (?P<action>\S+?)(?:, (?P<rest>.*))?$"
)
rows = []
for c in data:
    body = c.get("body", "")
    if MARKER not in body:
        continue
    # Author-trust gate (#249): drop non-allowlisted authors when strict.
    if _trust_present:
        author = (c.get("user") or {}).get("login", "")
        if author not in _allow:
            continue
    # Take everything after the marker; one or more lines.
    after = body.split(MARKER, 1)[1].lstrip("\n")
    for line in after.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        ts, stage, action, rest = m["ts"], m["stage"], m["action"], m["rest"] or ""
        if stage_filter and stage != stage_filter:
            continue
        if action_filter and action != action_filter:
            continue
        # Parse "k: v, k: v" — unquote values produced by log-stage.sh's
        # quoter. The regex-split approach was unsafe: a quoted value
        # containing ", " plus a key-like suffix (e.g. "hello, reason: x")
        # would be split inside the quotes. Walk the rest string with
        # quote-awareness so `, ` boundaries inside `"..."` are ignored.
        def split_pairs(s):
            chunks, buf, in_quote, i, n = [], [], False, 0, len(s)
            while i < n:
                c = s[i]
                if in_quote:
                    buf.append(c)
                    if c == '\\' and i + 1 < n:
                        buf.append(s[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        in_quote = False
                    i += 1
                    continue
                if c == '"':
                    in_quote = True
                    buf.append(c)
                    i += 1
                    continue
                # Boundary candidate: ", " followed by `<key>: `.
                if (c == ',' and i + 1 < n and s[i + 1] == ' '
                        and re.match(r"[A-Za-z_][\w-]*: ", s[i + 2:i + 64])):
                    chunks.append(''.join(buf))
                    buf = []
                    i += 2
                    continue
                buf.append(c)
                i += 1
            if buf:
                chunks.append(''.join(buf))
            return chunks

        pairs = []
        if rest:
            for chunk in split_pairs(rest):
                if ": " not in chunk:
                    continue
                k, v = chunk.split(": ", 1)
                if v.startswith('"') and v.endswith('"'):
                    v = unescape(v[1:-1])
                pairs.append(f"{k}={v}")
        rows.append((ts, stage, action, pairs))
rows.sort(key=lambda r: r[0])
if latest and rows:
    rows = rows[-1:]
for ts, stage, action, pairs in rows:
    safe = [scrub(ts), scrub(stage), scrub(action)] + [scrub(p) for p in pairs]
    print("\t".join(safe))
PY
