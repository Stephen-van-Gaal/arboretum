#!/usr/bin/env bash
# owner: pipeline-state-tracking
# log-stage.sh — Write a pipeline-state log entry: rewrite the
# current-stage header in the issue body (LWW) AND post a journey-log
# comment (naturally serialized by GitHub).
#
# See docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws9-state-tracking-design.md.
#
# Usage:
#   bash scripts/log-stage.sh <issue-number> <stage-name> <action> [<key>=<value>]...
#
# Actions (D5 vocab + CWD-2): entered, exited, skipped, re-entered, summary, repair, dispatched.
#
# Exit codes:
#   0 — both ops succeeded
#   1 — bad args / gh missing / unauthenticated
#   2 — body-edit op failed
#   3 — comment-post op failed
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "log-stage.sh requires bash" >&2; exit 1; }

# Marker strings used in the issue-body header block (D3). Exported so
# the python3 heredocs can read them via os.environ — single source of
# truth across bash + python.
readonly PIPELINE_STATE_MARKER_OPEN="<!-- pipeline-state:current-stage -->"
readonly PIPELINE_STATE_MARKER_CLOSE="<!-- /pipeline-state:current-stage -->"
readonly PIPELINE_STATE_LOG_MARKER="<!-- pipeline-state:log -->"
export PIPELINE_STATE_MARKER_OPEN PIPELINE_STATE_MARKER_CLOSE PIPELINE_STATE_LOG_MARKER

# Internal subcommand used by smoke tests to exercise the marker-block
# rewriter as a pure function (no gh I/O). Prints the rewritten body to stdout.
if [ "${1:-}" = "--rewrite-body-only" ]; then
  [ "$#" -eq 3 ] || { echo "Usage: --rewrite-body-only <body-file> <stage>" >&2; exit 1; }
  BODY_FILE="$2"; NEW_STAGE="$3"
  [ -f "$BODY_FILE" ] || { echo "body file not found: $BODY_FILE" >&2; exit 1; }
  python3 - "$BODY_FILE" "$NEW_STAGE" <<'PY'
import os, re, sys
body = open(sys.argv[1], encoding="utf-8").read()
stage = sys.argv[2]
marker_open = os.environ["PIPELINE_STATE_MARKER_OPEN"]
marker_close = os.environ["PIPELINE_STATE_MARKER_CLOSE"]
block = f"{marker_open}\n**Current stage:** {stage}\n{marker_close}"
# Normalize-then-prepend repair model (OQ2 + CX1 + CX4):
# 1. Strip any well-formed open+close pairs (so the fresh block can
#    replace them at the top, regardless of where they originally sat).
# 2. Strip any remaining orphan opening markers (CX1: catches the case
#    where a well-formed block coexists with a later stray opener that
#    the old "open AND NOT close" detection missed). Strip is bounded to
#    the marker line + an optional adjacent **Current stage:** line so
#    we never consume real body text past it (CX4).
# 3. Prepend the fresh block at the top.
#
# The alternation `(?:\\n|\n|\Z)` tolerates both real newlines
# (production) and literal `\n` escapes (test fixture JSON-encoded
# bodies), and `\Z` covers the edge case where the orphan sits at
# end-of-string with no trailing newline.

# Step 1: strip well-formed open+close pairs.
pair_pattern = re.compile(
    re.escape(marker_open) + r".*?" + re.escape(marker_close),
    re.DOTALL,
)
body = pair_pattern.sub("", body)

# Step 2: strip remaining orphan opening markers (line-bounded).
orphan_pattern = (
    re.escape(marker_open)
    + r"(?:\\n|\n|\Z)"
    + r"(?:\*\*Current\s+stage:\*\*[^\n]*?(?:\\n|\n|\Z))?"
)
body = re.sub(orphan_pattern, "", body)

# Step 3: prepend fresh block, with a blank line before the rest of the body.
new = block + "\n\n" + body.lstrip("\n")
print(new, end="")
PY
  exit 0
fi

# Internal subcommand to exercise the log-line formatter as a pure
# function (no gh I/O). Prints the marker line then the formatted log
# line to stdout.
# LOG_STAGE_TS_OVERRIDE may be set in tests to fix the timestamp.
if [ "${1:-}" = "--emit-log-only" ]; then
  [ "$#" -ge 3 ] || { echo "Usage: --emit-log-only <stage> <action> [<key>=<value>]..." >&2; exit 1; }
  STAGE="$2"; ACTION="$3"; shift 3
  TS="${LOG_STAGE_TS_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  # Pass key=value pairs through python3 for D5-compliant escaping (Task 5 pins escape rules).
  python3 - "$TS" "$STAGE" "$ACTION" "$@" <<'PY'
import os, re, sys
ts, stage, action = sys.argv[1], sys.argv[2], sys.argv[3]
pairs = sys.argv[4:]
marker = os.environ["PIPELINE_STATE_LOG_MARKER"]
# Reject undefined characters per D5 (C5/CX2): the escape vocabulary
# defines exactly `\"`, `\\`, and `\n` — any other control character
# (including raw tab `\t`, carriage return `\r`, NUL, ESC, etc.) has
# no defined escape and must be rejected at write time rather than
# emitted ambiguously. `\n` (\x0a) is intentionally excluded from
# this set because it IS in the defined vocabulary.
_UNDEFINED = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\t]")
def render(pair):
    if "=" not in pair:
        sys.stderr.write(f"log-stage: malformed key=value pair: {pair!r}\n"); sys.exit(1)
    k, v = pair.split("=", 1)
    if _UNDEFINED.search(k):
        sys.stderr.write(f"log-stage: key {k!r} contains undefined control characters — rejected per D5\n"); sys.exit(1)
    if _UNDEFINED.search(v):
        sys.stderr.write(f"log-stage: value for key {k!r} contains undefined control characters (e.g. tab, \\r, ESC) — rejected per D5\n"); sys.exit(1)
    # Quote when value contains the `, ` delimiter or already contains a quote/backslash/newline.
    needs_quote = (", " in v) or ('"' in v) or ("\\" in v) or ("\n" in v)
    if needs_quote:
        esc = v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        return f'{k}: "{esc}"'
    return f"{k}: {v}"
rendered = ", ".join(render(p) for p in pairs)
line = f"- {ts} — {stage} {action}"
if rendered:
    line += ", " + rendered
print(marker)
print(line)
PY
  exit 0
fi

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1; shift
fi

usage() {
  cat >&2 <<'EOF'
Usage: log-stage.sh <issue-number> <stage-name> <action> [<key>=<value>]...
Valid actions: entered, exited, skipped, re-entered, summary, repair, dispatched
EOF
  exit 1
}

[ "$#" -ge 3 ] || usage

ISSUE="${1:?issue number required}"
STAGE="${2:?stage name required}"
ACTION="${3:?action required}"
shift 3

case "$ACTION" in
  entered|exited|skipped|re-entered|summary|repair|dispatched) ;;
  *) echo "log-stage.sh: invalid action '$ACTION' (valid: entered, exited, skipped, re-entered, summary, repair, dispatched)" >&2; exit 1 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "log-stage.sh requires the gh CLI" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "log-stage.sh: gh is not authenticated (run: gh auth login)" >&2; exit 1; }

PROJECT_DIR="${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TS="${LOG_STAGE_TS_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export LOG_STAGE_TS_OVERRIDE="$TS"  # Pass through to the --emit-log-only recursive invocation (T7).

# ── Operation 1: body edit (header LWW, D2/D3) ───────────────────────
# Test stubs bypass --jq, but production gh CLI honors it and extracts
# the body string. Rewriter is tolerant of either shape (it operates
# on the marker block, which doesn't appear in the JSON wrapper).
body_in=$(mktemp)
body_out=$(mktemp)
trap 'rm -f "$body_in" "$body_out"' EXIT

if ! ( cd "$PROJECT_DIR" && gh issue view "$ISSUE" --json body --jq .body ) > "$body_in" 2>/dev/null; then
  echo "log-stage.sh: failed to read issue #$ISSUE body" >&2
  exit 2
fi

# Detect malformed marker state (OQ2 + CX1): any unclosed opening
# marker. Counts opens vs closes — catches the case where a well-formed
# block coexists with a stray opener that the old "open AND NOT close"
# detection missed.
#
# Uses awk (not `grep -c | wc -l`) because awk always exits 0 and always
# prints exactly one number — the `grep -c ... || echo 0` idiom can
# double-emit ("0\n0") when grep finds nothing, breaking the numeric
# comparison under `set -e`.
malformed=0
open_count=$(awk '/<!-- pipeline-state:current-stage -->/{c++} END{print c+0}' "$body_in")
close_count=$(awk '/<!-- \/pipeline-state:current-stage -->/{c++} END{print c+0}' "$body_in")
if [ "$open_count" -gt "$close_count" ]; then
  malformed=1
fi

bash "$0" --rewrite-body-only "$body_in" "$STAGE" > "$body_out" \
  || { echo "log-stage.sh: marker-block rewrite failed" >&2; exit 2; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "would: gh issue edit $ISSUE --body-file <rewritten-body>"
  echo "(body content omitted for brevity — diff between current and rewritten differs in the marker block only)"
else
  if ! ( cd "$PROJECT_DIR" && gh issue edit "$ISSUE" --body-file "$body_out" >/dev/null 2>&1 ); then
    echo "log-stage.sh: body-edit (header write) failed for issue #$ISSUE" >&2
    exit 2
  fi
fi

# If we just repaired a malformed marker block, post a `repair` log
# comment before the normal log entry — distinct action vocabulary
# (D5) so the boot-banner narrative surface (D7) is not polluted.
if [ "$malformed" -eq 1 ]; then
  repair_body=$(mktemp)
  bash "$0" --emit-log-only "$STAGE" repair event=malformed-current-stage-markers > "$repair_body" \
    || { rm -f "$repair_body"; echo "log-stage.sh: failed to format repair log entry" >&2; }
  if [ -f "$repair_body" ]; then
    # Use || true: the repair entry is best-effort. The normal log entry
    # still attempts to post. A failed repair post is surfaced but does
    # not abort the script (the body has already been repaired in place;
    # losing the audit entry is degraded, not fatal).
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would: gh issue comment $ISSUE --body-file <repair-entry>"
      cat "$repair_body"
    else
      ( cd "$PROJECT_DIR" && gh issue comment "$ISSUE" --body-file "$repair_body" >/dev/null 2>&1 ) \
        || echo "log-stage.sh: repair log entry post failed for issue #$ISSUE — body was repaired but audit entry missing" >&2
    fi
    rm -f "$repair_body"
  fi
fi

# ── Operation 2: comment post (log entry, D2 op 2 / D4 / D5) ─────────
# GitHub serializes comment creation server-side; no two writers create
# "the same comment," so this op has natural append-only semantics.
comment_body=$(mktemp)
# Replace trap with the expanded cleanup list (D2/D9: log post is independent).
trap 'rm -f "$body_in" "$body_out" "$comment_body"' EXIT

bash "$0" --emit-log-only "$STAGE" "$ACTION" "$@" > "$comment_body" \
  || { echo "log-stage.sh: log-line formatter failed" >&2; exit 3; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "would: gh issue comment $ISSUE --body-file <comment>"
  cat "$comment_body"
else
  if ! ( cd "$PROJECT_DIR" && gh issue comment "$ISSUE" --body-file "$comment_body" >/dev/null 2>&1 ); then
    echo "log-stage.sh: comment-post (log entry) failed for issue #$ISSUE — body-edit already applied" >&2
    exit 3
  fi
fi

exit 0
