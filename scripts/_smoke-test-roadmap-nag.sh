#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# ci-parallel: safe
# Smoke test for nag.sh — bootstrap, throttle (day + week), strategic-review-due,
# and stubbed-gh tests for maintain-overdue (count threshold + silent degradation).
# Usage: bash scripts/_smoke-test-roadmap-nag.sh
# Exit 0 if all cases pass, 1 if any fail.

set -euo pipefail

[ -z "${BASH_VERSION:-}" ] && { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAG_SCRIPT="$SCRIPT_DIR/roadmap/nag.sh"
LIB_SCRIPT="$SCRIPT_DIR/roadmap/lib.sh"

[ -f "$LIB_SCRIPT" ] || { echo "FAIL: lib.sh not found" >&2; exit 1; }
[ -f "$NAG_SCRIPT" ] || { echo "FAIL: nag.sh not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf 'detail:\n%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# ── Helpers ───────────────────────────────────────────────────────────

# Create a minimal git-initialised fixture directory.
new_fixture() {
  local name="$1"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/.arboretum"
  git -C "$fix" init -q 2>/dev/null
  git -C "$fix" config user.email "fixture@test.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" -c commit.gpgsign=false \
    commit -q --allow-empty -m "seed" 2>/dev/null
  echo "$fix"
}

# Write a minimal roadmap.config.yaml to a fixture.
# $2 = last_reviewed date (YYYY-MM-DD); $3 = review_cadence_weeks (default 12).
write_config() {
  local fix="$1" last_reviewed="$2" cadence="${3:-12}"
  cat > "$fix/roadmap.config.yaml" <<EOF
profile: minimal
time_horizon: "Through 2026-Q3"
last_reviewed: ${last_reviewed}
review_cadence_weeks: ${cadence}
wip_limit: 1
component_values:
  - core
EOF
}

# Pre-write a pulse file with explicit nag_last_fired state.
# $2 = ISO8601 for strategic-review-due last-fired, or "" for absent.
write_pulse() {
  local fix="$1" stale_ts="${2:-}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$stale_ts" ]; then
    cat > "$fix/.arboretum/roadmap-pulse.json" <<EOF
{
  "bootstrapped_at": "${now}",
  "last_maintain_run": "${now}",
  "last_revise_run": "${now}",
  "last_retro_completed": null,
  "nag_last_fired": {
    "strategic-review-due": "${stale_ts}"
  },
  "sprint_alerts_fired": {}
}
EOF
  else
    cat > "$fix/.arboretum/roadmap-pulse.json" <<EOF
{
  "bootstrapped_at": "${now}",
  "last_maintain_run": "${now}",
  "last_revise_run": "${now}",
  "last_retro_completed": null,
  "nag_last_fired": {},
  "sprint_alerts_fired": {}
}
EOF
  fi
}

# Date N days ago as ISO8601 UTC (YYYY-MM-DDT00:00:00Z).
days_ago_ts() {
  python3 -c "
from datetime import datetime, timezone, timedelta
d = datetime.now(timezone.utc).date() - timedelta(days=int('$1'))
print(str(d) + 'T00:00:00Z')
"
}

# Run nag.sh with CWD pointing to a fixture.
run_nag() {
  local fix="$1"
  ( cd "$fix" && bash "$NAG_SCRIPT" 2>/dev/null )
}

# Run nag.sh with a fake authenticated gh binary on PATH.
# Caller sets STUB_* env vars to control gh responses.
run_nag_gh() {
  local fix="$1"; shift
  ( cd "$fix" && PATH="$FAKE_BIN:$PATH" env "$@" bash "$NAG_SCRIPT" 2>/dev/null )
}

# Run nag.sh with a fake unauthenticated gh on PATH (simulates no-gh-available).
run_nag_noauth() {
  local fix="$1"
  ( cd "$fix" && PATH="$FAKE_BIN_NOAUTH:$PATH" bash "$NAG_SCRIPT" 2>/dev/null )
}

TODAY="$(date -u +%Y-%m-%d)"

# ── Fake gh binaries for stubbed tests ────────────────────────────────

# Authenticated stub — STUB_* env vars drive responses.
FAKE_BIN="$ROOT_TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Stub gh. Responds to auth status and issue list --json --jq 'length'.
ARGS="$*"
if [[ "$ARGS" == *"auth status"* ]]; then exit 0; fi
if [[ "$ARGS" == *"no:label is:open"* ]]; then echo "${STUB_UNTRIAGED:-0}"; exit 0; fi
if [[ "$ARGS" == *"provisionally-stale"* ]];  then echo "${STUB_STALE:-0}"; exit 0; fi
if [[ "$ARGS" == *"agent-ready"* ]];           then echo "${STUB_AGENT_READY:-0}"; exit 0; fi
if [[ "$ARGS" == *"horizon:now"* ]];           then echo "${STUB_WIP:-0}"; exit 0; fi
echo "${STUB_OPEN:-0}"; exit 0
GHEOF
chmod +x "$FAKE_BIN/gh"

# Unauthenticated stub — auth status always fails. Used for silent-degradation tests.
FAKE_BIN_NOAUTH="$ROOT_TMP/bin_noauth"
mkdir -p "$FAKE_BIN_NOAUTH"
cat > "$FAKE_BIN_NOAUTH/gh" <<'GHEOF'
#!/usr/bin/env bash
# Stub gh that simulates "gh installed but not authenticated".
exit 1
GHEOF
chmod +x "$FAKE_BIN_NOAUTH/gh"

# ── Case 1: Bootstrap creates a well-formed pulse file ─────────────────

fix=$(new_fixture case1)
write_config "$fix" "$TODAY"
run_nag_noauth "$fix" > /dev/null
[ -f "$fix/.arboretum/roadmap-pulse.json" ] \
  || fail "Case 1: pulse file not created after nag.sh run"
python3 - "$fix/.arboretum/roadmap-pulse.json" <<'PYEOF' || fail "Case 1: pulse file schema wrong"
import json, sys
d = json.load(open(sys.argv[1]))
required = ['bootstrapped_at','last_maintain_run','last_revise_run',
            'last_retro_completed','nag_last_fired','sprint_alerts_fired']
for k in required:
    assert k in d, f'missing key: {k}'
assert isinstance(d['nag_last_fired'], dict), 'nag_last_fired must be dict'
PYEOF
ok "Case 1: bootstrap creates well-formed pulse file"

# ── Case 2: Strategic review overdue + no previous nag → nag fires ────

fix=$(new_fixture case2)
write_config "$fix" "2024-01-01" 12    # 84 weeks overdue
write_pulse "$fix" ""                  # nag_last_fired empty
out=$(run_nag_noauth "$fix")
echo "$out" | grep -q "Strategic review" \
  || fail "Case 2: expected strategic-review-due nag to fire" "$out"
ok "Case 2: strategic-review-due fires when overdue and never throttled"

# ── Case 3: Strategic review not due → no nag ─────────────────────────

fix=$(new_fixture case3)
write_config "$fix" "$TODAY" 12        # reviewed today — 0 days since
write_pulse "$fix" ""
out=$(run_nag_noauth "$fix")
echo "$out" | grep -q "Strategic review" \
  && fail "Case 3: unexpected strategic review nag when review is current" "$out" || true
ok "Case 3: strategic-review-due suppressed when review is current"

# ── Case 4: Overdue but nag fired today → day throttle suppresses it ──
# (strategic-review-due uses _throttled_week, so "fired today" = < 7 days)

fix=$(new_fixture case4)
write_config "$fix" "2024-01-01" 12
write_pulse "$fix" "${TODAY}T00:00:00Z"   # nag fired today
out=$(run_nag_noauth "$fix")
echo "$out" | grep -q "Strategic review" \
  && fail "Case 4: weekly throttle should suppress nag fired today" "$out" || true
ok "Case 4: weekly throttle suppresses nag fired today"

# ── Case 5: Overdue but nag fired 8 days ago → throttle expired, fires ─

fix=$(new_fixture case5)
write_config "$fix" "2024-01-01" 12
OLD_TS="$(days_ago_ts 8)"
write_pulse "$fix" "$OLD_TS"
out=$(run_nag_noauth "$fix")
echo "$out" | grep -q "Strategic review" \
  || fail "Case 5: nag should fire when last fired 8 days ago (> 7-day window)" "$out"
ok "Case 5: weekly throttle expires after 7 days — nag fires again"

# ── Case 6: nag_last_fired updated in pulse after firing ──────────────

fix=$(new_fixture case6)
write_config "$fix" "2024-01-01" 12
write_pulse "$fix" ""
run_nag_noauth "$fix" > /dev/null
python3 - "$fix/.arboretum/roadmap-pulse.json" <<'PYEOF' || fail "Case 6: nag_last_fired not updated"
import json, sys
d = json.load(open(sys.argv[1]))
fired = d.get('nag_last_fired', {})
assert 'strategic-review-due' in fired, 'strategic-review-due not in nag_last_fired after fire'
PYEOF
ok "Case 6: nag_last_fired recorded in pulse after nag fires"

# ── Case 7: No roadmap.config.yaml → nag.sh exits silently ───────────

fix=$(new_fixture case7)    # no write_config call
out=$(run_nag_noauth "$fix")
[ -z "$out" ] || fail "Case 7: expected silent exit when config absent" "$out"
ok "Case 7: nag.sh exits silently with no roadmap.config.yaml"

# ── Case 8: Pulse idempotent when no nags fire ────────────────────────

fix=$(new_fixture case8)
write_config "$fix" "$TODAY" 12            # review not due
write_pulse "$fix" "${TODAY}T00:00:00Z"    # nag already throttled today
PULSE1="$(cat "$fix/.arboretum/roadmap-pulse.json")"
run_nag_noauth "$fix" > /dev/null
PULSE2="$(cat "$fix/.arboretum/roadmap-pulse.json")"
[ "$PULSE1" = "$PULSE2" ] \
  || fail "Case 8: pulse changed between runs with no nags firing"
ok "Case 8: pulse file idempotent when no nags fire"

# ── Cases 9-11: maintain-overdue with stubbed gh ──────────────────────

# Write a pulse with last_maintain_run 10 days ago and no previous maintain nag.
write_maintain_pulse() {
  local fix="$1"
  local old_ts
  old_ts="$(days_ago_ts 10)"
  cat > "$fix/.arboretum/roadmap-pulse.json" <<EOF
{
  "bootstrapped_at": "${old_ts}",
  "last_maintain_run": "${old_ts}",
  "last_revise_run": "${old_ts}",
  "last_retro_completed": null,
  "nag_last_fired": {},
  "sprint_alerts_fired": {}
}
EOF
}

# ── Case 9: maintain-overdue fires when untriaged >= 3 (stubbed gh) ───

fix=$(new_fixture case9)
write_config "$fix" "$TODAY"
write_maintain_pulse "$fix"
out=$(run_nag_gh "$fix" STUB_UNTRIAGED=5)
echo "$out" | grep -q "Maintain last run" \
  || fail "Case 9: expected maintain-overdue nag with 5 untriaged" "$out"
ok "Case 9: maintain-overdue fires with gh stub — 5 untriaged"

# ── Case 10: maintain-overdue silent when untriaged < 3 ───────────────

fix=$(new_fixture case10)
write_config "$fix" "$TODAY"
write_maintain_pulse "$fix"
out=$(run_nag_gh "$fix" STUB_UNTRIAGED=1)
echo "$out" | grep -q "Maintain last run" \
  && fail "Case 10: unexpected maintain-overdue nag with only 1 untriaged" "$out" || true
ok "Case 10: maintain-overdue silent when untriaged < 3"

# ── Case 11: gh-gated nags silent when gh unauthenticated; strategic-review still fires ─

fix=$(new_fixture case11)
write_config "$fix" "2024-01-01" 12   # strategic review overdue
write_maintain_pulse "$fix"            # last_maintain_run 10d ago — would fire if gh worked
out=$(run_nag_noauth "$fix")
echo "$out" | grep -q "Strategic review" \
  || fail "Case 11a: strategic-review-due must fire — it's gh-independent" "$out"
echo "$out" | grep -q "Maintain last run" \
  && fail "Case 11b: maintain-overdue must be silent when gh unauthenticated" "$out" || true
ok "Case 11: strategic-review fires + maintain-overdue silent (gh unauthenticated)"

# ── Cases 12-13: stale-flagged-today (stubbed gh) ─────────────────────

fix=$(new_fixture case12)
write_config "$fix" "$TODAY"
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_STALE=2)
echo "$out" | grep -q "provisionally-stale" \
  || fail "Case 12: expected stale-flagged-today nag with 2 stale issues" "$out"
ok "Case 12: stale-flagged-today fires with 2 provisionally-stale issues"

fix=$(new_fixture case13)
write_config "$fix" "$TODAY"
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_STALE=0)
echo "$out" | grep -q "provisionally-stale" \
  && fail "Case 13: unexpected stale-flagged-today nag with 0 stale" "$out" || true
ok "Case 13: stale-flagged-today silent when 0 provisionally-stale"

# ── Cases 14-15: agent-ready-while-WIP-full (stubbed gh) ──────────────

fix=$(new_fixture case14)
write_config "$fix" "$TODAY"   # wip_limit: 1 from write_config
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_WIP=1 STUB_AGENT_READY=2)
echo "$out" | grep -q "WIP full" \
  || fail "Case 14: expected agent-ready-while-WIP-full nag" "$out"
ok "Case 14: agent-ready-while-WIP-full fires when WIP at limit + agent-ready waiting"

fix=$(new_fixture case15)
write_config "$fix" "$TODAY"
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_WIP=1 STUB_AGENT_READY=0)
echo "$out" | grep -q "WIP full" \
  && fail "Case 15: unexpected agent-ready nag with 0 agent-ready" "$out" || true
ok "Case 15: agent-ready-while-WIP-full silent when 0 agent-ready issues"

# ── Cases 16-17: profile-graduation-lean (stubbed gh) ─────────────────

fix=$(new_fixture case16)
write_config "$fix" "$TODAY"   # profile: minimal from write_config
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_OPEN=25)
echo "$out" | grep -q "Minimal profile" \
  || fail "Case 16: expected profile-graduation-lean nag at 25 open issues" "$out"
ok "Case 16: profile-graduation-lean fires with 25 open issues on minimal"

fix=$(new_fixture case17)
write_config "$fix" "$TODAY"
write_pulse "$fix" ""
out=$(run_nag_gh "$fix" STUB_OPEN=5)
echo "$out" | grep -q "Minimal profile" \
  && fail "Case 17: unexpected profile-graduation-lean nag with 5 open" "$out" || true
ok "Case 17: profile-graduation-lean silent when open issues < 20"

echo ""
echo "All smoke tests passed."
