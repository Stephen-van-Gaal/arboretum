#!/usr/bin/env bash
# owner: review-stage
# validate-review-manifest.sh — enforce the review-manifest seam schema.
#   validate-review-manifest.sh <manifest-file>
# Exit 0 = valid; exit 1 = schema violation (first offending field to stderr).
set -euo pipefail
f="${1:?usage: validate-review-manifest.sh <manifest-file>}"
fail() { echo "INVALID manifest: $1" >&2; exit 1; }

jq -e 'type=="object"' "$f" >/dev/null 2>&1 || fail "not a JSON object"
jq -e 'has("lane") and (.lane|type=="string")' "$f" >/dev/null || fail "lane (string) missing"
jq -e 'has("files_reviewed") and (.files_reviewed|type=="array")' "$f" >/dev/null || fail "files_reviewed (array) missing"
jq -e 'has("surface_identified") and (.surface_identified|type=="string")' "$f" >/dev/null || fail "surface_identified (string) missing"
jq -e 'has("coverage") and (.coverage|type=="array")' "$f" >/dev/null || fail "coverage (array) missing"
jq -e 'has("findings") and (.findings|type=="array")' "$f" >/dev/null || fail "findings (array) missing"
jq -e '(.coverage|all(has("category") and has("status") and has("why")))' "$f" >/dev/null || fail "coverage[] entries require category, status, why"
jq -e '(.findings|all(has("severity") and has("location") and has("recommendation")))' "$f" >/dev/null || fail "findings[] entries require severity, location, recommendation"
jq -e '(.coverage|all(.status=="evaluated" or .status=="cleared"))' "$f" >/dev/null || fail "coverage[].status must be evaluated|cleared"
jq -e '(.findings|all(.severity=="critical" or .severity=="warning" or .severity=="info"))' "$f" >/dev/null || fail "findings[].severity must be critical|warning|info"
exit 0
