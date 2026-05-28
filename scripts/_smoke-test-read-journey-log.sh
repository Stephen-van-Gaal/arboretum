#!/usr/bin/env bash
# owner: pipeline-state-tracking
# _smoke-test-read-journey-log.sh — Verify scripts/read-journey-log.sh
# against the line-format contract defined by scripts/log-stage.sh.
# Usage: bash scripts/_smoke-test-read-journey-log.sh
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
READER="$REPO_ROOT/scripts/read-journey-log.sh"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# Fixture: simulate gh api response for issue comments containing a
# journey-log marker block produced by log-stage.sh's --emit-log-only.
# log-stage.sh's marker is:
#   <!-- pipeline-state:log -->
#   - <ts> — <stage> <action>[, <key>: <value>]...
FIXTURE_COMMENTS="$ROOT_TMP/comments.json"
cat > "$FIXTURE_COMMENTS" <<'JSON'
[
  {"id": 1, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:00Z — /land entered"},
  {"id": 2, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:01Z — /land summary, phase: 1, terminal: false"},
  {"id": 3, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:02Z — /land summary, phase: 3, head_sha: abc1234, head_sha_unchanged_count: 0"},
  {"id": 4, "body": "unrelated comment with no marker"}
]
JSON

# Install a gh stub that returns the fixture for `gh api .../comments`.
BINDIR="$ROOT_TMP/.bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view") echo "owner/repo" ; exit 0 ;;
  "api "*) cat "$FIXTURE_COMMENTS"; exit 0 ;;
  *) echo "stub: unhandled: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
PATH="$BINDIR:$PATH"; export PATH

# ── Case 1: no args → usage + non-zero exit ────────────────────────────
out=$(bash "$READER" 2>&1) && fail "case 1 — no args should fail" "$out"
echo "$out" | grep -qi 'usage' || fail "case 1 — expected usage hint" "$out"
ok "case 1 — missing args exit non-zero"

# ── Case 2: read all entries — emit one TSV row per journey-log line ──
out=$(bash "$READER" 361 2>&1) || fail "case 2 — should succeed" "$out"
row_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ "$row_count" = "3" ] || fail "case 2 — expected 3 rows, got $row_count" "$out"
printf '%s\n' "$out" | head -1 | grep -q 'entered' \
  || fail "case 2 — first row should contain 'entered'" "$out"
ok "case 2 — three journey-log rows extracted"

# ── Case 3: TSV columns — timestamp, stage, action, then key=value ────
first=$(printf '%s\n' "$out" | head -1)
ts_col=$(printf '%s\n' "$first" | awk -F'\t' '{print $1}')
stage_col=$(printf '%s\n' "$first" | awk -F'\t' '{print $2}')
action_col=$(printf '%s\n' "$first" | awk -F'\t' '{print $3}')
[ "$ts_col" = "2026-05-28T12:00:00Z" ] || fail "case 3 — ts column wrong: $ts_col"
[ "$stage_col" = "/land" ] || fail "case 3 — stage column wrong: $stage_col"
[ "$action_col" = "entered" ] || fail "case 3 — action column wrong: $action_col"
ok "case 3 — TSV column layout correct"

# ── Case 4: --stage filter narrows to matching stage ──────────────────
out=$(bash "$READER" 361 --stage /land 2>&1) || fail "case 4 — should succeed" "$out"
row_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ "$row_count" = "3" ] || fail "case 4 — expected 3 /land rows, got $row_count" "$out"
ok "case 4 — --stage filter retains matching rows"

out=$(bash "$READER" 361 --stage /build 2>&1) || fail "case 4b — should succeed" "$out"
[ -z "$out" ] || fail "case 4b — --stage /build should match zero rows, got: $out"
ok "case 4b — --stage filter excludes non-matching"

# ── Case 5: --action filter narrows to matching action ────────────────
out=$(bash "$READER" 361 --action summary 2>&1) || fail "case 5 — should succeed" "$out"
row_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ "$row_count" = "2" ] || fail "case 5 — expected 2 summary rows, got $row_count" "$out"
ok "case 5 — --action filter retains summary rows only"

# ── Case 6: --latest returns only the most recent matching row ────────
out=$(bash "$READER" 361 --stage /land --action summary --latest 2>&1) \
  || fail "case 6 — should succeed" "$out"
row_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ "$row_count" = "1" ] || fail "case 6 — expected 1 row, got $row_count" "$out"
printf '%s\n' "$out" | grep -q 'head_sha=abc1234' \
  || fail "case 6 — latest summary row should include head_sha=abc1234" "$out"
ok "case 6 — --latest returns most recent matching row"

# ── Case 7: escape round-trip — values containing ", " and quotes ─────
LOG_STAGE="$REPO_ROOT/scripts/log-stage.sh"
emitted=$(LOG_STAGE_TS_OVERRIDE=2026-05-28T13:00:00Z \
  bash "$LOG_STAGE" --emit-log-only /land summary \
    'reason=stalled, no progress' \
    'note=value with "quote"')
# Build a comments fixture from the emitted line.
ROUND_FIXTURE="$ROOT_TMP/round.json"
python3 - "$emitted" > "$ROUND_FIXTURE" <<'PY'
import json, sys
body = sys.argv[1]
json.dump([{"id": 1, "body": body}], sys.stdout)
PY
# Repoint the existing gh stub by simply overwriting it.
cat > "$BINDIR/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view") echo "owner/repo"; exit 0 ;;
  "api "*) cat "$ROUND_FIXTURE"; exit 0 ;;
  *) echo "stub: unhandled: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(bash "$READER" 361 --action summary 2>&1)
printf '%s\n' "$out" | grep -q $'reason=stalled, no progress' \
  || fail "case 7 — comma-containing value not round-tripped" "$out"
printf '%s\n' "$out" | grep -q 'note=value with "quote"' \
  || fail "case 7 — quoted value not round-tripped" "$out"
ok "case 7 — escape round-trip preserves values"

# ── Case 8: Quote-aware split — value with key-like substring ─────────
# A value containing `", "` followed by a key-shaped suffix must NOT
# be split inside the quotes (Codex round-2 review on PR #362).
QUOTED_FIXTURE="$ROOT_TMP/quoted.json"
emitted2=$(LOG_STAGE_TS_OVERRIDE=2026-05-28T14:00:00Z \
  bash "$LOG_STAGE" --emit-log-only /land summary \
    'msg=hello, reason: wait' \
    'other=plain')
python3 - "$emitted2" > "$QUOTED_FIXTURE" <<'PY'
import json, sys
json.dump([{"id": 1, "body": sys.argv[1]}], sys.stdout)
PY
cat > "$BINDIR/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view") echo "owner/repo" ; exit 0 ;;
  "api "*) cat "$QUOTED_FIXTURE"; exit 0 ;;
  *) echo "stub: unhandled: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(bash "$READER" 361 --action summary 2>&1)
printf '%s\n' "$out" | grep -q $'msg=hello, reason: wait' \
  || fail "case 8 — quoted comma-with-key-suffix value mis-split" "$out"
printf '%s\n' "$out" | grep -q 'other=plain' \
  || fail "case 8 — plain key=value after quoted value lost" "$out"
# Negative: the value's interior "reason: wait" must NOT appear as a separate pair.
if printf '%s\n' "$out" | grep -qE '(^|\t)reason=wait(\t|$)'; then
  fail "case 8 — spurious 'reason=wait' pair leaked from inside quoted value" "$out"
fi
ok "case 8 — quote-aware split keeps inner key-shaped suffix inside the value"

# Case 8 mutated the gh stub to point at a different fixture; restore
# the original so any future cases reuse $FIXTURE_COMMENTS as Cases 1-6 do.
cat > "$BINDIR/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view") echo "owner/repo" ; exit 0 ;;
  "api "*) cat "$FIXTURE_COMMENTS"; exit 0 ;;
  *) echo "stub: unhandled: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"

echo "ALL PASS"
