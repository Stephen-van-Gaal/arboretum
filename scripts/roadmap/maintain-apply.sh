#!/usr/bin/env bash
# owner: roadmap
# Apply the non-interactive /roadmap maintain actions from a scan JSON.
#
# Consumes scripts/roadmap/maintain-scan.sh output. Applies only the
# high-confidence, reversible actions — auto-close, provisionally-resolved,
# provisionally-stale — each with an evidence comment. The untriaged and
# unshaped_next buckets are left for the interactive skill flow.
# It also reverts decayed agent-ready labels — agent_ready_invalidated
# (remove agent-ready) and agent_ready_stale (agent-ready -> agent-prep:in-progress).
#
#   --scan-file <path|->   scan JSON ('-' reads stdin)
#   --dry-run              print intended actions; mutate nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

scan_file=""
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --scan-file) scan_file="$2"; shift 2 ;;
    --dry-run)   dry_run=true;   shift ;;
    -h|--help)   sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$scan_file" ] || { echo "Missing --scan-file" >&2; exit 2; }
if [ "$scan_file" = "-" ]; then
  scan="$(cat)"
else
  [ -f "$scan_file" ] || { echo "Not a file: $scan_file" >&2; exit 1; }
  scan="$(cat "$scan_file")"
fi

echo "$scan" | jq -e . >/dev/null 2>&1 || { echo "Invalid scan JSON" >&2; exit 1; }

if ! $dry_run; then
  PROJECT_ROOT="$(roadmap_project_root)"
  export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_ROOT")}"
  roadmap_require_backend "$ROADMAP_BACKEND" || exit 1
fi

# Emit "<number>\t<evidence>" lines for one bucket.
bucket_rows() {
  echo "$scan" | jq -r --arg b "$1" '.buckets[$b][]? | "\(.number)\t\(.evidence)"'
}

apply_close() {
  local n="$1" ev="$2"
  local body="$ev. Closed by /roadmap maintain [auto-close]. Reopen if this was premature."
  if $dry_run; then
    echo "[dry-run] close #$n — $ev"
  elif roadmap_tracker_issue_close "$n" --reason completed --comment "$body" >/dev/null 2>&1; then
    echo "✓ closed #$n — $ev"
  else
    echo "⚠ could not close #$n (skipped)" >&2
  fi
}

apply_label() {
  # Label first, then comment — two commands, so report their outcomes
  # independently: a label that applied but whose comment failed must not
  # be reported as fully skipped.
  local n="$1" label="$2" ev="$3" note="$4"
  if $dry_run; then
    echo "[dry-run] label #$n $label — $ev"
    return
  fi
  if ! roadmap_tracker_issue_update "$n" --add-label "$label" >/dev/null 2>&1; then
    echo "⚠ could not add label $label to #$n (skipped)" >&2
    return
  fi
  if ! roadmap_tracker_issue_comment "$n" --body "$note" >/dev/null 2>&1; then
    echo "⚠ labelled #$n $label but could not post comment" >&2
    return
  fi
  echo "✓ labelled #$n $label — $ev"
}

apply_relabel() {
  # Remove one label, optionally add another, then comment. Used for the
  # decay buckets. Reports label and comment outcomes independently.
  # Labels passed in must not contain spaces.
  local n="$1" remove="$2" add="$3" ev="$4" note="$5"
  if $dry_run; then
    echo "[dry-run] relabel #$n -$remove${add:+ +$add} — $ev"
    return
  fi
  local args=(--remove-label "$remove")
  [ -n "$add" ] && args+=(--add-label "$add")
  if ! roadmap_tracker_issue_update "$n" "${args[@]}" >/dev/null 2>&1; then
    echo "⚠ could not relabel #$n (-$remove${add:+ +$add}) (skipped)" >&2
    return
  fi
  if ! roadmap_tracker_issue_comment "$n" --body "$note" >/dev/null 2>&1; then
    echo "⚠ relabelled #$n but could not post comment" >&2
    return
  fi
  echo "✓ relabelled #$n -$remove${add:+ +$add} — $ev"
}

while IFS=$'\t' read -r n ev; do
  [ -z "$n" ] && continue
  apply_close "$n" "$ev"
done < <(bucket_rows auto_close)

while IFS=$'\t' read -r n ev; do
  [ -z "$n" ] && continue
  apply_label "$n" "provisionally-resolved" "$ev" \
    "$ev. Flagged provisionally-resolved by /roadmap maintain — verify and close, or remove the label if more work is needed."
done < <(bucket_rows soft_resolved)

while IFS=$'\t' read -r n ev; do
  [ -z "$n" ] && continue
  apply_label "$n" "provisionally-stale" "$ev" \
    "$ev. Flagged provisionally-stale by /roadmap maintain — remove the label to keep this open, or close if no longer relevant."
done < <(bucket_rows orphan)

while IFS=$'\t' read -r n ev; do
  [ -z "$n" ] && continue
  apply_relabel "$n" "agent-ready" "" "$ev" \
    "$ev. **agent-ready removed** by /roadmap maintain — the agent-ready verification no longer holds. Re-run \`/roadmap agent-prep $n\` to re-verify."
done < <(bucket_rows agent_ready_invalidated)

while IFS=$'\t' read -r n ev; do
  [ -z "$n" ] && continue
  apply_relabel "$n" "agent-ready" "agent-prep:in-progress" "$ev" \
    "$ev. Reverted agent-ready → agent-prep:in-progress by /roadmap maintain — re-confirm timing with \`/roadmap agent-prep $n\` to restore it."
done < <(bucket_rows agent_ready_stale)
