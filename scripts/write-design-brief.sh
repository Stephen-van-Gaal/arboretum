#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# write-design-brief.sh — Write a structured design brief to
# .arboretum/design-briefs/<issue>.md, the handoff from /design's resident
# elicit phase to its dispatched produce driver (#944, epic #516 slice 4).
#
# Usage:
#   bash scripts/write-design-brief.sh <issue> <<'JSON'
#   {"branch1-mode": "...", "requirements": "...", "kind": "buildable|shaping",
#    "survey-findings": [...], "decisions": [...], "customer-experience-notes": "..."}
#   JSON
# `kind` is optional; omit for the default (buildable). Structurally records
# the S2 kind:shaping decision elicit made (#692), rather than leaving produce
# to infer it from free-text Requirements prose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/scrub-control-chars.sh"

ISSUE="${1:-}"
if [ -z "$ISSUE" ]; then
  echo "write-design-brief.sh: missing positional <issue> argument" >&2
  exit 1
fi

case "$ISSUE" in
  ''|*[!0-9]*|0|0[0-9]*)
    echo "write-design-brief.sh: <issue> must be a strictly positive integer (no 0, no leading zeros), got: $ISSUE" >&2
    exit 1
    ;;
esac

PAYLOAD=$(cat)
if [ -z "$PAYLOAD" ]; then
  echo "write-design-brief.sh: empty payload on stdin" >&2
  exit 1
fi

BRIEFS_DIR=".arboretum/design-briefs"
mkdir -p "$BRIEFS_DIR"
BRIEF="$BRIEFS_DIR/${ISSUE}.md"

export ISSUE BRIEF PAYLOAD
python3 - <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

issue = os.environ["ISSUE"]
brief_path = os.environ["BRIEF"]
raw = os.environ["PAYLOAD"]

# env bridge — scripts/lib/scrub-control-chars.sh (CLAUDE.md § Defense in
# depth). requirements/decisions/survey-findings may echo GitHub-issue-body
# text carried in via /start's $ARGUMENTS — author-controlled, scrub at source.
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])
_CTRL_SURROGATE = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS_SURROGATE"])


def scrub(text):
    text = _CTRL.sub("", text)
    text = _CTRL_SURROGATE.sub("", text)
    return text


def table_cell(text):
    # Escape '|' and collapse embedded newlines so a crafted decision value
    # cannot break out of its Markdown table cell into extra rows/lines.
    return scrub(text).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def text_field(value):
    # Coerce any JSON value to a safe string for rendering: None and
    # non-string types (list, dict, number, bool) all become "" rather
    # than reaching scrub()/table_cell() and crashing on .replace().
    return value if isinstance(value, str) else ""


try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    sys.stderr.write(f"write-design-brief.sh: malformed JSON on stdin: {exc}\n")
    sys.exit(1)

if not isinstance(payload, dict):
    sys.stderr.write(f"write-design-brief.sh: payload must be a JSON object, got: {type(payload).__name__}\n")
    sys.exit(1)

VALID_MODES = {"brainstorm", "investigate", "coverage-baseline", "none"}
mode = payload.get("branch1-mode")
if not isinstance(mode, str) or mode not in VALID_MODES:
    sys.stderr.write(f"write-design-brief.sh: branch1-mode must be one of {sorted(VALID_MODES)}, got: {mode!r}\n")
    sys.exit(1)

requirements = payload.get("requirements")
if not isinstance(requirements, str) or not requirements.strip():
    sys.stderr.write("write-design-brief.sh: requirements is required and must be a non-empty string\n")
    sys.exit(1)
requirements = scrub(requirements)
if not requirements.strip():
    sys.stderr.write("write-design-brief.sh: requirements is required and must be non-empty after control-character scrubbing\n")
    sys.exit(1)

kind = payload.get("kind")
if kind is not None and kind not in ("buildable", "shaping"):
    sys.stderr.write(f"write-design-brief.sh: kind must be 'buildable' or 'shaping' (or omitted), got: {kind!r}\n")
    sys.exit(1)

survey_findings = payload.get("survey-findings")
if survey_findings is None:
    survey_findings = []
elif not isinstance(survey_findings, list):
    sys.stderr.write("write-design-brief.sh: survey-findings must be an array of objects\n")
    sys.exit(1)
if not all(isinstance(x, dict) for x in survey_findings):
    sys.stderr.write("write-design-brief.sh: survey-findings must be an array of objects\n")
    sys.exit(1)

decisions = payload.get("decisions")
if decisions is None:
    decisions = []
elif not isinstance(decisions, list):
    sys.stderr.write("write-design-brief.sh: decisions must be an array of objects\n")
    sys.exit(1)
if not all(isinstance(x, dict) for x in decisions):
    sys.stderr.write("write-design-brief.sh: decisions must be an array of objects\n")
    sys.exit(1)

cx_notes = payload.get("customer-experience-notes")
if cx_notes is not None and not isinstance(cx_notes, str):
    sys.stderr.write("write-design-brief.sh: customer-experience-notes must be a string (or omitted)\n")
    sys.exit(1)

lines = []
lines.append("---")
lines.append(f"date: {datetime.now(timezone.utc).strftime('%Y-%m-%d')}")
lines.append(f"related-issue: {issue}")
lines.append(f"branch1-mode: {mode}")
if kind == "shaping":
    lines.append("kind: shaping")
lines.append("---")
lines.append("")
lines.append(f"# Design Brief — #{issue}")
lines.append("")
lines.append("## Requirements")
lines.append("")
lines.append(requirements)

if survey_findings:
    lines.append("")
    lines.append("## Survey Findings")
    lines.append("")
    for finding in survey_findings:
        artifact = table_cell(text_field(finding.get("artifact")))
        why = table_cell(text_field(finding.get("why")))
        lines.append(f"- **{artifact}** — {why}")

if decisions:
    lines.append("")
    lines.append("## Decisions")
    lines.append("")
    lines.append("| Decision | Alternatives Considered | Rationale |")
    lines.append("|---|---|---|")
    for d in decisions:
        lines.append(
            f"| {table_cell(text_field(d.get('decision')))} | {table_cell(text_field(d.get('alternatives-considered')))} | {table_cell(text_field(d.get('rationale')))} |"
        )

if cx_notes and cx_notes.strip():
    lines.append("")
    lines.append("## Customer Experience Notes")
    lines.append("")
    lines.append(scrub(cx_notes))

with open(brief_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY

echo "$BRIEF"
