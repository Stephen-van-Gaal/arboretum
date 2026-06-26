#!/usr/bin/env bash
# owner: pipeline-context-ledger
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-read-pipeline-context.sh — Verify read-pipeline-context.sh emits a
# field only on a fresh-SHA hit; misses on stale SHA / missing file / unknown
# field; scrubs at the consumer layer (#665).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT/scripts/read-pipeline-context.sh"
[ -f "$READER" ] || { echo "FAIL: $READER not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# --- hermetic fixture repo + cache -----------------------------------------
REPO="$FIX/repo"
mkdir -p "$REPO/.arboretum"
git -C "$REPO" init -q
git -C "$REPO" config user.email f@e.com
git -C "$REPO" config user.name f
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
sha="$(git -C "$REPO" rev-parse HEAD)"

# Cache stamped with the current HEAD; issue body carries a control char (chr 7)
# to prove the consumer-layer scrub.
python3 - "$REPO/.arboretum/pipeline-context-cache.json" "$sha" <<'PY'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
data = {
    "head_sha": sha, "base_ref": "main", "written_at": "x",
    "issue": {"number": 665, "title": "T", "body": "b" + chr(7) + "x", "labels": ["x"]},
    "spec_index": "SPECTEXT", "changed_files": ["a", "b"], "diff_stat": "STAT",
}
json.dump(data, open(path, "w"))
PY

r() { (cd "$REPO" && bash "$READER" "$1" 2>/dev/null); }

[ "$(r issue | jq -r '.number')" = "665" ] && pass "fresh hit: issue number" || fail_case "issue miss on fresh SHA"
[ "$(r spec_index)" = "SPECTEXT" ] && pass "fresh hit: spec_index" || fail_case "spec_index wrong"
[ "$(r diff_stat)" = "STAT" ] && pass "fresh hit: diff_stat" || fail_case "diff_stat wrong"
[ "$(r changed_files | jq -r '.[0]')" = "a" ] && pass "fresh hit: changed_files" || fail_case "changed_files wrong"

# Consumer-layer scrub: the chr(7) in the issue body must not survive emit.
body="$(r issue | jq -r '.body')"
[ "$body" = "bx" ] && pass "consumer-layer scrub on emit" || fail_case "body not scrubbed on read" "got=$(printf '%s' "$body" | od -c | head -1)"

r bogus >/dev/null 2>&1 && fail_case "unknown field should miss" || pass "unknown field misses"

# Advance HEAD → stale → miss.
git -C "$REPO" commit -q --allow-empty -m next
r issue >/dev/null 2>&1 && fail_case "stale SHA should miss" || pass "stale SHA misses"

# Missing file → miss.
rm "$REPO/.arboretum/pipeline-context-cache.json"
r issue >/dev/null 2>&1 && fail_case "missing file should miss" || pass "missing file misses"

# Empty computed field is a MISS, not an empty hit (Codex 1 / #697 review).
git -C "$REPO" commit -q --allow-empty -m freshA
shaA="$(git -C "$REPO" rev-parse HEAD)"
printf '{"head_sha":"%s","written_at":"x","issue":{"number":1},"spec_index":"","changed_files":[],"diff_stat":""}\n' "$shaA" \
  > "$REPO/.arboretum/pipeline-context-cache.json"
r spec_index >/dev/null 2>&1 && fail_case "empty spec_index should miss" || pass "empty field misses"
r changed_files >/dev/null 2>&1 && fail_case "empty changed_files should miss" || pass "empty list field misses"

# spec_index stale when REGISTER.md mtime is newer than the cache file's (Codex 3
# / #697 review). Force REGISTER's mtime clearly newer via os.utime so the case
# is deterministic regardless of filesystem mtime granularity.
mkdir -p "$REPO/docs"
printf '{"head_sha":"%s","written_at":"2000-01-01T00:00:00Z","issue":{"number":1},"spec_index":"OLDINDEX","changed_files":["a"],"diff_stat":"d"}\n' "$shaA" \
  > "$REPO/.arboretum/pipeline-context-cache.json"
printf '## Spec Index\nnewer\n' > "$REPO/docs/REGISTER.md"
python3 -c "
import os
cache='$REPO/.arboretum/pipeline-context-cache.json'
reg='$REPO/docs/REGISTER.md'
os.utime(reg, (os.path.getmtime(cache)+100, os.path.getmtime(cache)+100))
"
r spec_index >/dev/null 2>&1 && fail_case "stale spec_index (REGISTER newer) should miss" || pass "stale spec_index misses on newer REGISTER"
# Other fields are unaffected by REGISTER freshness.
[ "$(r diff_stat)" = "d" ] && pass "diff_stat unaffected by REGISTER mtime" || fail_case "diff_stat wrongly gated by REGISTER"

if [ "$fail" -ne 0 ]; then echo "read-pipeline-context smoke: FAIL" >&2; exit 1; fi
echo "read-pipeline-context smoke: PASS"
