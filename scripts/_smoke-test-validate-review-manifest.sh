#!/usr/bin/env bash
# owner: review-stage
# _smoke-test-validate-review-manifest.sh — accept a well-formed manifest, reject malformed ones.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-review-manifest.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail_count=0
cat > "$TMP/ok.json" <<'JSON'
{ "lane": "ai-surface",
  "files_reviewed": ["skills/finish/SKILL.md"],
  "surface_identified": "one shell heredoc rendering Bash text",
  "coverage": [ {"category":"tool-abuse","status":"cleared","why":"input is a path-list, not interpolated"} ],
  "findings": [ {"severity":"info","location":"skills/finish/SKILL.md:42","recommendation":"none"} ] }
JSON
cat > "$TMP/bad-missing.json" <<'JSON'
{ "lane":"general-security", "files_reviewed": [], "surface_identified": "x", "coverage": [] }
JSON
cat > "$TMP/bad-enum.json" <<'JSON'
{ "lane":"correctness", "files_reviewed": [], "surface_identified": "x", "coverage": [],
  "findings": [ {"severity":"BOGUS","location":"a","recommendation":"b"} ] }
JSON
cat > "$TMP/bad-coverage-entry.json" <<'JSON'
{ "lane":"ai-surface", "files_reviewed": [], "surface_identified": "x",
  "coverage": [ {"status":"cleared","why":"y"} ], "findings": [] }
JSON
cat > "$TMP/bad-finding-entry.json" <<'JSON'
{ "lane":"ai-surface", "files_reviewed": [], "surface_identified": "x", "coverage": [],
  "findings": [ {"severity":"info","recommendation":"b"} ] }
JSON
expect() { # <label> <file> <expected-exit>
  local label="$1" file="$2" want="$3" rc=0
  bash "$VALIDATE" "$file" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc" >&2; ((fail_count++)) || true
  fi
}
expect "well-formed"          "$TMP/ok.json"               0
expect "missing findings"     "$TMP/bad-missing.json"      1
expect "bad severity"         "$TMP/bad-enum.json"         1
expect "coverage missing key" "$TMP/bad-coverage-entry.json" 1
expect "finding missing key"  "$TMP/bad-finding-entry.json"  1
if [ "$fail_count" -gt 0 ]; then echo "FAIL: $fail_count case(s)" >&2; exit 1; fi
echo "PASS: validate-review-manifest.sh — 5 cases"
