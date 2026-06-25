#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# build-review-request.sh — construct the ReviewRequest the pipeline stage hands the
# dispatcher (#791 D2, section-dispatch element 1: the context-parameterized request).
#
#   build-review-request.sh --altitude <design|build|finish> \
#                           --artifact <doc|diff|tree> \
#                           --base <ref> [--brief <file|->]
#
# Emits {altitude, artifact, base, brief}. altitude + artifact are the dimensions
# review-registry-filter.sh selects workers on; base scopes the diff; brief is the
# free-text context the workers receive. The brief is author-controlled by THIS pipeline
# (not external input), so it is not scrubbed here — runtime worker OUTPUT is scrubbed at
# its adapter boundary (review-adapter-codex.sh), which is where untrusted text enters.
set -euo pipefail

ALTITUDE=""; ARTIFACT=""; BASE=""; BRIEF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --altitude) ALTITUDE="${2:-}"; shift 2 ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --base)     BASE="${2:-}"; shift 2 ;;
    --brief)
      if [ "${2:-}" = "-" ]; then BRIEF="$(cat)"; else
        [ -f "${2:-}" ] || { echo "build-review-request: brief file not found: ${2:-}" >&2; exit 2; }
        BRIEF="$(cat "$2")"
      fi
      shift 2 ;;
    *) echo "build-review-request: unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$ALTITUDE" in design|build|finish) ;; *) echo "build-review-request: --altitude must be design|build|finish (got '$ALTITUDE')" >&2; exit 2 ;; esac
case "$ARTIFACT" in doc|diff|tree) ;; *) echo "build-review-request: --artifact must be doc|diff|tree (got '$ARTIFACT')" >&2; exit 2 ;; esac
[ -n "$BASE" ] || { echo "build-review-request: --base <ref> is required" >&2; exit 2; }

jq -n \
  --arg altitude "$ALTITUDE" \
  --arg artifact "$ARTIFACT" \
  --arg base "$BASE" \
  --arg brief "$BRIEF" \
  '{altitude: $altitude, artifact: $artifact, base: $base, brief: $brief}'
