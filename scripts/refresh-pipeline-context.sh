#!/usr/bin/env bash
# owner: pipeline-context-ledger
# refresh-pipeline-context.sh — write .arboretum/pipeline-context-cache.json.
#
# Computes the ship-tail handoff fields (issue snapshot, REGISTER spec-index,
# diff/changed-files) for the current HEAD, scrubs all author-controlled strings
# via the shared scrub primitive, and writes the cache atomically, SHA-stamped.
# See docs/contracts/refresh-pipeline-context.contract.md.
#
# Usage: bash scripts/refresh-pipeline-context.sh <issue>
# Exit: 0 — cache written (degraded inputs yield empty fields, not failure).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/scrub-control-chars.sh
. "$SCRIPT_DIR/lib/scrub-control-chars.sh"   # exports ARBO_CTRL_CHAR_CLASS

ISSUE="${1:?usage: refresh-pipeline-context.sh <issue>}"
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CACHE_DIR="$PROJECT_DIR/.arboretum"
CACHE_FILE="$CACHE_DIR/pipeline-context-cache.json"
BASE_REF="${ARBO_PIPELINE_BASE_REF:-main}"
mkdir -p "$CACHE_DIR"

g() { git -C "$PROJECT_DIR" "$@"; }
HEAD_SHA="$(g rev-parse HEAD 2>/dev/null || echo "")"

# Best-effort field computation: any unavailable input yields an empty field.
DIFF_STAT="$(g diff --stat "${BASE_REF}...HEAD" 2>/dev/null || true)"
CHANGED="$(g diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || true)"
SPEC_INDEX="$(bash "$SCRIPT_DIR/read-doc-section.sh" "$PROJECT_DIR/docs/REGISTER.md" "Spec Index" 2>/dev/null || true)"
ISSUE_JSON="$(gh issue view "$ISSUE" --json number,title,body,labels 2>/dev/null || echo '{}')"

tmp="$(mktemp "$CACHE_DIR/pipeline-context-cache.json.XXXXXX")"
if ARBO_PC_HEAD="$HEAD_SHA" ARBO_PC_BASE="$BASE_REF" \
   ARBO_PC_DIFF_STAT="$DIFF_STAT" ARBO_PC_CHANGED="$CHANGED" \
   ARBO_PC_SPEC_INDEX="$SPEC_INDEX" ARBO_PC_ISSUE_JSON="$ISSUE_JSON" \
   python3 - > "$tmp" <<'PY'
import json, os, re, datetime
cls = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])
def scrub(v):
    if isinstance(v, str):  return cls.sub("", v)
    if isinstance(v, list): return [scrub(x) for x in v]
    if isinstance(v, dict): return {k: scrub(x) for k, x in v.items()}
    return v
try:
    raw = json.loads(os.environ.get("ARBO_PC_ISSUE_JSON") or "{}")
except json.JSONDecodeError:
    raw = {}
issue = {
    "number": raw.get("number"),
    "title":  scrub(raw.get("title") or ""),
    "body":   scrub(raw.get("body") or ""),
    "labels": [scrub((l or {}).get("name", "")) for l in (raw.get("labels") or [])],
}
changed = [scrub(x) for x in (os.environ.get("ARBO_PC_CHANGED") or "").splitlines() if x]
out = {
    "head_sha":      os.environ.get("ARBO_PC_HEAD") or "",
    "base_ref":      os.environ.get("ARBO_PC_BASE") or "",
    "written_at":    datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "issue":         issue,
    "spec_index":    scrub(os.environ.get("ARBO_PC_SPEC_INDEX") or ""),
    "changed_files": changed,
    "diff_stat":     scrub(os.environ.get("ARBO_PC_DIFF_STAT") or ""),
}
print(json.dumps(out, indent=2))
PY
then
  mv "$tmp" "$CACHE_FILE"
else
  # The python step failed (e.g. python3 missing / heredoc error). Never mv an
  # empty/partial temp over the cache — that would violate the atomic-write
  # contract. Leave any existing cache untouched; consumers miss and fall back.
  rm -f "$tmp"
fi
