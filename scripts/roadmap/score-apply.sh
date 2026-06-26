#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# Execute the combine/delete/decompose dispositions stored in the score cache.
#
# Consumes the JSON cache produced by score-cache.sh. Applies only the safe,
# reversible actions — planned close for delete (non-epic). combine and
# decompose are skill-orchestrated or nominate-only respectively and are never
# auto-executed here.
#
# type:epic (class=="orchestrator") issues are NEVER auto-closed or combined —
# they are listed under NEEDS-CONFIRM and skipped. This is a hard safety guard.
#
#   --cache <file>   score cache JSON (required)
#   --dry-run        print intended actions; mutate nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cache=""
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   cache="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$cache" ] || { echo "Missing --cache" >&2; exit 2; }
[ -f "$cache" ] || { echo "Not a file: $cache" >&2; exit 1; }

cache_json="$(cat "$cache")"
echo "$cache_json" | jq -e . >/dev/null 2>&1 || { echo "Invalid cache JSON" >&2; exit 1; }

if ! $dry_run; then
  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"
  PROJECT_ROOT="$(roadmap_project_root)"
  export ROADMAP_BACKEND="${ROADMAP_BACKEND:-$(roadmap_backend "$PROJECT_ROOT")}"
  roadmap_require_backend "$ROADMAP_BACKEND" || exit 1
fi

# Emit the plan/needs-confirm/nominate lines for all dispositions.
printf '%s' "$cache_json" | jq -r '
  to_entries[] as $e
  | ($e.key) as $n | ($e.value) as $v
  | if $v.disposition=="delete" and $v.class=="work-unit" then
      "PLAN: close #\($n) (delete) — reason: \($v.value_description // "scored delete")"
    elif $v.disposition=="delete" then
      "NEEDS-CONFIRM: #\($n) delete (class is \($v.class // "unknown") — skipped)"
    elif $v.disposition=="combine" and $v.class=="orchestrator" then
      "NEEDS-CONFIRM: #\($n) combine (type:epic — skipped)"
    elif $v.disposition=="combine" then
      "PLAN: combine #\($n) → anchor #\($v.anchor // "unknown") (body-review gate — skill-driven)"
    elif $v.disposition=="decompose" then
      "NOMINATE: #\($n) decompose (nominate-only; no auto-create)"
    else empty end'

$dry_run && exit 0

# Non-dry-run: execute only the safe delete closes (class=="work-unit" allowlist).
# combine body-merge is skill-orchestrated (see SKILL.md).
# decompose is nominate-only — never executed here.
while IFS= read -r n; do
  [ -z "$n" ] && continue
  # Fetch live labels, body, and state — re-check authoritative state before any mutation.
  issue_json="$(roadmap_tracker_issue_show "$n" --json labels,body,state 2>/dev/null)" || {
    echo "NEEDS-CONFIRM: #$n — label/body fetch failed; skipping to preserve safety" >&2
    continue
  }
  [ -n "$issue_json" ] || { echo "NEEDS-CONFIRM: #$n — empty issue response; skipping" >&2; continue; }
  # Already-closed guard — issue was closed between scoring and apply; skip silently.
  if printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null | grep -qi "^closed$"; then
    echo "skip: #$n already closed — no action taken"
    continue
  fi
  # Authoritative label guard — class in the cache is model-assigned and may be stale.
  # If the issue carries type:epic, skip it regardless of what the cache says.
  if printf '%s' "$issue_json" | jq -r '.labels // [] | .[].name' 2>/dev/null | grep -qx "type:epic"; then
    echo "NEEDS-CONFIRM: #$n carries type:epic — skipped"
    continue
  fi
  # Body-sha revalidation — skip close if the body changed since scoring (cache stale).
  # Capture body via command substitution (strips trailing newline) before hashing so
  # the sha matches the cache convention: printf '%s' "$body" | shasum (no trailing newline).
  # Piping jq -r directly to shasum would hash "body\n" and never match the cache.
  current_body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
  current_sha="$(printf '%s' "$current_body" | shasum -a 256 | cut -c1-12)"
  cached_sha="$(printf '%s' "$cache_json" | jq -r --arg n "$n" '.[$n].body_sha // ""')"
  if [ "$current_sha" != "$cached_sha" ]; then
    echo "NEEDS-CONFIRM: #$n — cache stale (body changed since scoring — must re-score); skipped" >&2
    continue
  fi
  reason="$(printf '%s' "$cache_json" | jq -r --arg n "$n" '.[$n].value_description // "scored delete"')"
  # Post evidence comment FIRST; skip close if comment fails (no close without audit trail).
  if ! roadmap_tracker_issue_comment "$n" \
    --body "Closed by \`/roadmap score --apply\` (disposition: delete). Evidence: $reason. Reversible — reopen if mis-scored." \
    >/dev/null 2>&1; then
    echo "NEEDS-CONFIRM: #$n — evidence comment failed; skipping close to preserve audit trail" >&2
    continue
  fi
  if roadmap_tracker_issue_close "$n" --reason "not planned" >/dev/null 2>&1; then
    echo "✓ closed #$n — $reason"
  else
    echo "⚠ could not close #$n (skipped)" >&2
  fi
done < <(printf '%s' "$cache_json" | jq -r \
  'to_entries[] | select(.value.disposition=="delete" and .value.class=="work-unit") | .key')
