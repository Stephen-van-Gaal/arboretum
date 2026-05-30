#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-read-journey-log.sh — Contract test for
# docs/contracts/read-journey-log.contract.md. Asserts RJL-1..RJL-7
# against scripts/read-journey-log.sh.
#
# read-journey-log.sh shells out to `gh` twice:
#   1. gh repo view --json nameWithOwner --jq .nameWithOwner
#   2. gh api repos/<repo>/issues/<n>/comments --paginate
# We shadow PATH with a `gh` stub that serves a fixture comments payload
# from $GH_COMMENTS_JSON, so the parser runs against deterministic input
# with no network. The fixture log lines use the real producer format
# (log-stage.sh): "- <ts> — <stage> <action>[, <k>: <v>, ...]" with an
# em-dash separator. Picked up automatically by ci-checks.sh's
# === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/read-journey-log.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

GH_STUB_DIR=$(mktemp -d)
trap 'rm -rf "$GH_STUB_DIR"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# ── gh stub ──────────────────────────────────────────────────────────
# Responds to:
#   gh repo view --json nameWithOwner --jq .nameWithOwner  → prints "foo/bar"
#   gh api repos/.../comments --paginate                   → prints $GH_COMMENTS_JSON
cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  repo)
    # gh repo view --json nameWithOwner --jq .nameWithOwner
    printf 'foo/bar\n'
    exit 0
    ;;
  api)
    printf '%s' "${GH_COMMENTS_JSON:-[]}"
    exit 0
    ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$GH_STUB_DIR/gh"

# Build a comments payload (a JSON array of {body:...}) with python3 so
# the em-dash and control sequences are correctly encoded.
# Two log comments + one non-log comment.
COMMENTS=$(python3 -c "
import json
log = '<!-- pipeline-state:log -->'
comments = [
    # earlier timestamp
    {'body': log + '\n- 2026-05-30T10:00:00Z — /land summary, head_sha: abc123, head_sha_unchanged_count: 0'},
    # later timestamp, with a quoted value containing a comma+key-like text
    {'body': log + '\n- 2026-05-30T11:00:00Z — /land summary, note: \"hello, world\", head_sha: def456'},
    # a /build entered row at a middle timestamp
    {'body': log + '\n- 2026-05-30T10:30:00Z — /build entered'},
    # a non-log comment (no marker) — must contribute nothing
    {'body': 'just a regular comment, no marker here'},
]
print(json.dumps(comments))
")

run() { GH_COMMENTS_JSON="$COMMENTS" PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" "$@" 2>"$GH_STUB_DIR/.err"; }

# RJL-1 — all rows: 3 log rows, sorted ascending by timestamp, 3 tab-fields min
out=$(run 42); rc=$?
nrows=$(printf '%s\n' "$out" | grep -c .)
first_ts=$(printf '%s\n' "$out" | head -1 | awk -F'\t' '{print $1}')
last_ts=$(printf '%s\n' "$out" | tail -1 | awk -F'\t' '{print $1}')
if [ "$rc" = 0 ] && [ "$nrows" = 3 ] \
   && [ "$first_ts" = "2026-05-30T10:00:00Z" ] \
   && [ "$last_ts" = "2026-05-30T11:00:00Z" ]; then
  pass RJL-1
else
  fail_case RJL-1 "rc=$rc nrows=$nrows first=$first_ts last=$last_ts out=$out err=$(cat "$GH_STUB_DIR/.err")"
fi

# Verify column order on the first row: ts, stage, action
f1=$(printf '%s\n' "$out" | head -1 | awk -F'\t' '{print $2}')
f2=$(printf '%s\n' "$out" | head -1 | awk -F'\t' '{print $3}')
[ "$f1" = "/land" ] && [ "$f2" = "summary" ] && pass "RJL-1 (column order)" || fail_case "RJL-1 (column order)" "stage=$f1 action=$f2"

# RJL-2 — non-log comment contributes nothing (only 3 rows, never 4)
[ "$nrows" = 3 ] && pass RJL-2 || fail_case RJL-2 "expected 3 rows (non-log excluded), got $nrows"

# RJL-3 — --stage filter
out3=$(run 42 --stage /build); rc=$?
n3=$(printf '%s\n' "$out3" | grep -c .)
stage3=$(printf '%s\n' "$out3" | head -1 | awk -F'\t' '{print $2}')
[ "$rc" = 0 ] && [ "$n3" = 1 ] && [ "$stage3" = "/build" ] && pass "RJL-3 (--stage)" || fail_case "RJL-3 (--stage)" "rc=$rc n=$n3 out=$out3"
# --action filter
out3b=$(run 42 --action summary); rc=$?
n3b=$(printf '%s\n' "$out3b" | grep -c .)
[ "$rc" = 0 ] && [ "$n3b" = 2 ] && pass "RJL-3 (--action)" || fail_case "RJL-3 (--action)" "rc=$rc n=$n3b out=$out3b"

# RJL-4 — --latest returns exactly the most-recent row
out4=$(run 42 --latest); rc=$?
n4=$(printf '%s\n' "$out4" | grep -c .)
ts4=$(printf '%s\n' "$out4" | head -1 | awk -F'\t' '{print $1}')
[ "$rc" = 0 ] && [ "$n4" = 1 ] && [ "$ts4" = "2026-05-30T11:00:00Z" ] && pass RJL-4 || fail_case RJL-4 "rc=$rc n=$n4 ts=$ts4 out=$out4"

# RJL-5 — key=value pairs emitted as tab fields; quoted value unquoted, comma preserved
# The 11:00 row has note: "hello, world" and head_sha: def456
latest_row=$(printf '%s\n' "$out" | grep '2026-05-30T11:00:00Z')
# tokenize on tabs, find the note= field
note_field=$(printf '%s\n' "$latest_row" | tr '\t' '\n' | grep '^note=')
sha_field=$(printf '%s\n' "$latest_row" | tr '\t' '\n' | grep '^head_sha=')
if [ "$note_field" = "note=hello, world" ] && [ "$sha_field" = "head_sha=def456" ]; then
  pass RJL-5
else
  fail_case RJL-5 "note=[$note_field] sha=[$sha_field] row=$latest_row"
fi

# RJL-6 — gh missing → exit 1. Build a shadow PATH dir that symlinks the
# core tools the script needs (python3, mktemp, date, cat, etc.) but
# deliberately omits `gh`, so `command -v gh` fails while the rest of the
# script can still run up to that guard.
NOGH_BIN=$(mktemp -d); trap 'rm -rf "$GH_STUB_DIR" "$NOGH_BIN"' EXIT
for t in python3 mktemp date cat rm bash sed grep awk; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOGH_BIN/$t" 2>/dev/null || true
done
out6=$(PATH="$NOGH_BIN" bash "$PROBE" 42 2>/dev/null); rc=$?
[ "$rc" = 1 ] && pass RJL-6 || fail_case RJL-6 "rc=$rc out=$out6"

# RJL-7 — no matching comments → exit 0, empty stdout
out7=$(GH_COMMENTS_JSON='[]' PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" 42 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out7" ] && pass RJL-7 || fail_case RJL-7 "rc=$rc out=[$out7]"

[ "$fail" = 0 ] && echo "read-journey-log contract: ALL PASS" || exit 1
