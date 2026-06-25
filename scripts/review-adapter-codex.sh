#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# review-adapter-codex.sh — the `runtime` adapter for the codex reviewer (#791 D5).
# Maps codex `review --json` output (schema: verdict/summary/findings[]) onto the shared
# review-manifest (docs/contracts/review-manifest.contract.md), so a deterministic CLI
# reviewer emits the same schema as the skill-invoked lanes.
#
#   <codex --json> | review-adapter-codex.sh
#   review-adapter-codex.sh <codex-json-file>
#
# TRUST BOUNDARY (section-dispatch element 7): codex output is fresh untrusted input
# flowing back into Claude's context, so we scrub control chars at THIS boundary before
# it is parsed/rendered. LLM-free + deterministic.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/scrub-control-chars.sh
. "$DIR/lib/scrub-control-chars.sh"

in="${1:--}"
if [ "$in" = "-" ]; then raw="$(cat)"; else
  [ -f "$in" ] || { echo "review-adapter-codex: file not found: $in" >&2; exit 2; }
  raw="$(cat "$in")"
fi

# Scrub at the boundary, then require codex shape.
scrubbed="$(printf '%s' "$raw" | scrub_control_chars)"
printf '%s' "$scrubbed" | jq -e 'type=="object" and has("findings") and (.findings|type=="array")' >/dev/null 2>&1 \
  || { echo "review-adapter-codex: input is not codex review --json (needs object with findings[])" >&2; exit 2; }

# Map codex severity (critical|high|medium|low) → manifest severity (critical|warning|info).
# critical→critical; high/medium→warning; low→info; unknown→warning (surface, never silent info).
printf '%s' "$scrubbed" | jq '
  def sev: {"critical":"critical","high":"warning","medium":"warning","low":"info"}[.] // "warning";
  {
    lane: "codex",
    files_reviewed: ([.findings[].file] | map(select(. != null)) | unique),
    surface_identified: "diff",
    coverage: [ { category: "codex-review",
                  status: "evaluated",
                  why: ((.summary // "codex review") | tostring) } ],
    findings: [ .findings[] | {
      severity: ((.severity // "") | ascii_downcase | sev),
      location: ((.file // "?") + ":" + ((.line_start // 0) | tostring)),
      recommendation: ( if ((.recommendation // "") | length) > 0
                        then .recommendation
                        else ((.title // "finding") + " — " + (.body // "")) end )
    } ]
  }'
