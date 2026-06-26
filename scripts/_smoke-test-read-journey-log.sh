#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# ci-parallel: safe
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
# Every comment carries a user.login (#249 author-trust). id1-4 are authored
# by the allowlisted `trusted-bot`; id5 is a forged entry from a non-allowlisted
# `attacker` (distinct head_sha=deadbeef so cases can assert its presence/absence).
cat > "$FIXTURE_COMMENTS" <<'JSON'
[
  {"id": 1, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:00Z — /land entered"},
  {"id": 2, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:01Z — /land summary, phase: 1, terminal: false"},
  {"id": 3, "user": {"login": "trusted-bot"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:02Z — /land summary, phase: 3, head_sha: abc1234, head_sha_unchanged_count: 0"},
  {"id": 4, "user": {"login": "trusted-bot"}, "body": "unrelated comment with no marker"},
  {"id": 5, "user": {"login": "attacker"}, "body": "<!-- pipeline-state:log -->\n- 2026-05-28T12:00:03Z — /land summary, phase: 9, head_sha: deadbeef, head_sha_unchanged_count: 1"}
]
JSON

# Trust configs (#249). Strict = present key allowlisting `trusted-bot`; absent
# = no key (permissive migration path). Existing cases run under strict mode via
# the exported override so only `trusted-bot` entries surface.
TRUST_PRESENT_CFG="$ROOT_TMP/present.yml"
cat > "$TRUST_PRESENT_CFG" <<'YML'
trust:
  journey_log_authors:
    - trusted-bot
YML
TRUST_ABSENT_CFG="$ROOT_TMP/absent.yml"
cat > "$TRUST_ABSENT_CFG" <<'YML'
layer: 2
YML
export TRUST_CONFIG_OVERRIDE="$TRUST_PRESENT_CFG"

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
json.dump([{"id": 1, "user": {"login": "trusted-bot"}, "body": body}], sys.stdout)
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
json.dump([{"id": 1, "user": {"login": "trusted-bot"}, "body": sys.argv[1]}], sys.stdout)
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

# ── Case 9: forged entry from a non-allowlisted author is NOT surfaced ──
# Strict mode (exported TRUST_CONFIG_OVERRIDE → present.yml allowlists trusted-bot).
# The attacker's id5 row (head_sha=deadbeef) must be dropped; only the 3 trusted
# marker rows survive.
out=$(bash "$READER" 361 2>/dev/null) || fail "case 9 — should succeed" "$out"
printf '%s\n' "$out" | grep -q 'deadbeef' \
  && fail "case 9 — forged attacker row must be dropped under strict mode" "$out"
row_count=$(printf '%s\n' "$out" | grep -c . || true)
[ "$row_count" = "3" ] || fail "case 9 — expected 3 trusted rows, got $row_count" "$out"
ok "case 9 — non-allowlisted author dropped (strict mode)"

# ── Case 10: absent key → permissive, all rows surfaced + stderr warning ──
err=$(TRUST_CONFIG_OVERRIDE="$TRUST_ABSENT_CFG" bash "$READER" 361 2>&1 >/dev/null)
out=$(TRUST_CONFIG_OVERRIDE="$TRUST_ABSENT_CFG" bash "$READER" 361 2>/dev/null)
printf '%s\n' "$out" | grep -q 'deadbeef' \
  || fail "case 10 — permissive mode should surface the attacker row too" "$out"
printf '%s\n' "$err" | grep -qi 'trust.journey_log_authors not configured' \
  || fail "case 10 — expected stderr migration warning" "$err"
ok "case 10 — absent key = permissive + warning"

# ── Case 11: control characters in a logged value are scrubbed at the boundary ──
CTRL_COMMENTS="$ROOT_TMP/ctrl.json"
printf '[{"id":1,"user":{"login":"trusted-bot"},"body":"<!-- pipeline-state:log -->\\n- 2026-05-28T12:00:00Z — /land summary, note: \\"a\\u001b[31mb\\""}]' > "$CTRL_COMMENTS"
cat > "$BINDIR/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "repo view") echo "owner/repo" ; exit 0 ;;
  "api "*) cat "$CTRL_COMMENTS"; exit 0 ;;
  *) echo "stub: unhandled: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BINDIR/gh"
out=$(bash "$READER" 361 2>/dev/null)
printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')" \
  && fail "case 11 — ESC byte must be scrubbed from output" "$out"
# Only the control byte (ESC) is stripped; the printable residue '[31m' remains
# (same behaviour as refresh-next-cache.sh — the scrub neutralizes terminal
# control, not harmless printable text).
printf '%s\n' "$out" | grep -Fq 'note=a[31mb' \
  || fail "case 11 — printable residue should remain (a[31mb)" "$out"
ok "case 11 — control chars scrubbed at read boundary"

# ── Case 12: malformed trust config → fail CLOSED (exit non-zero), not permissive ──
# A present-but-unparseable .arboretum.yml must NOT silently widen to permissive
# (#249 review, Copilot+Codex). Restore the base fixture for the gh stub first.
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
BAD_CFG="$ROOT_TMP/bad.yml"
# A list item with no parent key is invalid YAML-lite (yaml-lite rejects it).
printf 'trust:\n  journey_log_authors:\n   - a\n  - b\nbad: : :\n' > "$BAD_CFG"
if TRUST_CONFIG_OVERRIDE="$BAD_CFG" bash "$READER" 361 >/dev/null 2>&1; then
  fail "case 12 — malformed trust config must fail closed (non-zero exit)"
fi
ok "case 12 — malformed trust config fails closed (no silent permissive)"

echo "ALL PASS"
