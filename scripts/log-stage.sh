#!/usr/bin/env bash
# owner: pipeline-state-tracking
# log-stage.sh — Write pipeline state: set the exclusive current-stage
# label (stage:<name>, LWW) AND post a journey-log comment (naturally
# serialized by the tracker backend).
#
# See docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws9-state-tracking-design.md.
#
# Usage:
#   bash scripts/log-stage.sh <issue-number> <stage-name> <action> [<key>=<value>]...
#
# Actions (D5 vocab + CWD-2): entered, exited, skipped, re-entered, summary, dispatched.
#
# Exit codes:
#   0 — both ops succeeded
#   1 — bad args / tracker missing / unauthenticated
#   2 — stage-label write failed
#   3 — comment-post op failed
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "log-stage.sh requires bash" >&2; exit 1; }

# Marker prefixing each journey-log comment. Exported so the --emit-log-only
# python3 heredoc can read it via os.environ.
readonly PIPELINE_STATE_LOG_MARKER="<!-- pipeline-state:log -->"
export PIPELINE_STATE_LOG_MARKER

# Internal subcommand to exercise the log-line formatter as a pure
# function (no tracker I/O). Prints the marker line then the formatted log
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=roadmap/lib.sh
source "$SCRIPT_DIR/roadmap/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: log-stage.sh <issue-number> <stage-name> <action> [<key>=<value>]...
Valid actions: entered, exited, skipped, re-entered, summary, dispatched
EOF
  exit 1
}

[ "$#" -ge 3 ] || usage

ISSUE="${1:?issue number required}"
STAGE="${2:?stage name required}"
ACTION="${3:?action required}"
shift 3

case "$ACTION" in
  entered|exited|skipped|re-entered|summary|dispatched) ;;
  *) echo "log-stage.sh: invalid action '$ACTION' (valid: entered, exited, skipped, re-entered, summary, dispatched)" >&2; exit 1 ;;
esac

# Defensive: the stage must be a `/`-prefixed lowercase-kebab token, so the
# derived stage:* label is well-formed. Stage names come from stage skills
# (trusted), but reject a malformed value up front rather than create a garbage
# label (reviewer finding, #570). Validated before any backend work.
case "$STAGE" in
  /[a-z]*) case "${STAGE#/}" in *[!a-z-]*) STAGE_BAD=1 ;; *) STAGE_BAD=0 ;; esac ;;
  *) STAGE_BAD=1 ;;
esac
[ "$STAGE_BAD" -eq 0 ] || { echo "log-stage.sh: stage '$STAGE' is not a /lowercase-kebab token — refusing to set a malformed stage label" >&2; exit 1; }

PROJECT_DIR="${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_DIR")}"
roadmap_probe_backend_access "$ROADMAP_BACKEND" "$PROJECT_DIR" || exit 1
TS="${LOG_STAGE_TS_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export LOG_STAGE_TS_OVERRIDE="$TS"  # Pass through to the --emit-log-only recursive invocation (T7).

# ── Operation 1: set the current-stage label (exclusive, LWW) ────────
# Stage names carry a leading slash (/design); the label form drops it
# (stage:design). refresh-stage-cache.sh restores the slash on read so the
# cache `stage` field is unchanged.
stage_value="${STAGE#/}"   # validated /lowercase-kebab above
if [ "$DRY_RUN" -eq 1 ]; then
  echo "would: set exclusive label stage:$stage_value on issue $ISSUE (removing any other stage:* label)"
else
  if ! ( cd "$PROJECT_DIR" && roadmap_set_prefix_exclusive_label "$ISSUE" stage "$stage_value" >/dev/null 2>&1 ); then
    echo "log-stage.sh: setting stage label failed for issue #$ISSUE" >&2
    exit 2
  fi
fi

# ── Operation 2: comment post (log entry, D2 op 2 / D4 / D5) ─────────
# The tracker backend serializes comment creation server-side; no two writers
# create "the same comment," so this op has natural append-only semantics.
comment_body=$(mktemp)
trap 'rm -f "$comment_body"' EXIT

bash "$0" --emit-log-only "$STAGE" "$ACTION" "$@" > "$comment_body" \
  || { echo "log-stage.sh: log-line formatter failed" >&2; exit 3; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "would: tracker issue comment $ISSUE --body-file <comment>"
  cat "$comment_body"
else
  if ! ( cd "$PROJECT_DIR" && roadmap_tracker_issue_comment "$ISSUE" --body-file "$comment_body" >/dev/null 2>&1 ); then
    echo "log-stage.sh: comment-post (log entry) failed for issue #$ISSUE — body-edit already applied" >&2
    exit 3
  fi
fi

exit 0
