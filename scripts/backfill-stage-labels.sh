#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# backfill-stage-labels.sh — One-shot migration (#570). For each OPEN issue
# carrying a legacy current-stage marker block in its body: set the
# corresponding exclusive stage:* label, then rewrite the body with the
# block removed. Idempotent — issues without a block are skipped.
#
# Usage: bash scripts/backfill-stage-labels.sh [project-dir]
# Exit:  0 on completion (per-issue failures are logged, not fatal).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "requires bash" >&2; exit 1; }

PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=roadmap/lib.sh
source "$SCRIPT_DIR/roadmap/lib.sh"
export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_DIR")}"
roadmap_require_backend "$ROADMAP_BACKEND" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

# NOTE: matches GitHub-style markdown markers only. Azure DevOps legacy work
# items that stored the marker in HTML-escaped form are not migrated here; ADO
# adopters self-heal on each item's next log-stage write. A dedicated ADO
# legacy-marker pass is a follow-up (needs an ADO marker-format fixture).
SCAN_LIMIT=1000
numbers=$( cd "$PROJECT_DIR" && roadmap_tracker_issue_list --state open --limit "$SCAN_LIMIT" --json number --jq '.[].number' 2>/dev/null || true )
issue_count=$(printf '%s\n' "$numbers" | grep -c . || true)
if [ "$issue_count" -ge "$SCAN_LIMIT" ]; then
  echo "WARN: scanned the first $SCAN_LIMIT open issues (the cap) — a larger repo may have un-migrated items; raise SCAN_LIMIT and re-run." >&2
fi

while IFS= read -r n; do
  [ -z "$n" ] && continue
  body=$( cd "$PROJECT_DIR" && roadmap_tracker_issue_show "$n" --json body --jq .body 2>/dev/null || true )
  # Extract the legacy stage value, if any.
  stage=$(BODY="$body" python3 -c '
import os, re
b = os.environ.get("BODY","").replace("\\n","\n")
# Constrain the captured stage to the known shape (slash + lowercase-kebab):
# the issue body is author-controlled, and a bare \S+ would capture control
# characters (ESC etc.) into the label value. Charset-constraining IS the
# source-side scrub here — a non-conforming body simply yields no match and
# the issue is skipped rather than migrated into a garbage stage:* label.
m = re.search(r"<!--\s*pipeline-state:current-stage\s*-->\s*\*\*Current\s+stage:\*\*\s*(/[a-z][a-z-]*)(?![A-Za-z0-9])", b)
print(m.group(1) if m else "")
')
  [ -z "$stage" ] && continue
  stage_value="${stage#/}"
  echo "backfill: #$n -> stage:$stage_value"
  ( cd "$PROJECT_DIR" && roadmap_set_prefix_exclusive_label "$n" stage "$stage_value" >/dev/null 2>&1 ) \
    || { echo "  WARN: label set failed for #$n" >&2; continue; }
  # Strip the marker block from the body and write it back.
  stripped=$(BODY="$body" python3 -c '
import os, re
b = os.environ.get("BODY","").replace("\\n","\n")
b = re.sub(r"<!--\s*pipeline-state:current-stage\s*-->.*?<!--\s*/pipeline-state:current-stage\s*-->\s*", "", b, flags=re.DOTALL)
print(b, end="")
')
  tmpf=$(mktemp); printf '%s' "$stripped" > "$tmpf"
  ( cd "$PROJECT_DIR" && roadmap_tracker_issue_update "$n" --body-file "$tmpf" >/dev/null 2>&1 ) \
    || echo "  WARN: body strip failed for #$n" >&2
  rm -f "$tmpf"
done <<< "$numbers"

echo "backfill complete."
