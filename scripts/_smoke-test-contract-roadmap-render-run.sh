#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-render-run.sh — Contract test for
# docs/contracts/roadmap-render-run.contract.md. Asserts RRR-1..RRR-6
# against scripts/roadmap/render-run.sh.
#
# render-run.sh supports a file-driven test mode (--board-file /
# --closed-file) that bypasses the config/gh guards, so we drive it
# against an inline board fixture with no network and no roadmap.config.
# This pins the --condensed orientation block's [roadmap] header marker +
# counts and its NOW: / ★ agent-ready: sections (what session-start.sh
# injects), and confirms the default view is the distinct full board.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/roadmap/render-run.sh"
[ -f "$RENDER" ] || { echo "FAIL: $RENDER not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# Board: 1 horizon:now, 2 horizon:next (one also agent-ready), 1 untriaged.
BOARD="$TMP/board.json"
cat > "$BOARD" <<'JSON'
[
  {"number":10,"title":"Now item","labels":[{"name":"horizon:now"}],"updatedAt":"2026-05-20T00:00:00Z","milestone":null},
  {"number":11,"title":"Next item","labels":[{"name":"horizon:next"}],"updatedAt":"2026-05-20T00:00:00Z","milestone":null},
  {"number":12,"title":"Ready item","labels":[{"name":"agent-ready"},{"name":"horizon:next"}],"updatedAt":"2026-05-20T00:00:00Z","milestone":null},
  {"number":13,"title":"Untriaged item","labels":[],"updatedAt":"2026-05-20T00:00:00Z","milestone":null}
]
JSON

cond=$(bash "$RENDER" --condensed --board-file "$BOARD"); rc=$?
full=$(bash "$RENDER" --board-file "$BOARD"); rcf=$?

# RRR-1 — condensed leads with a [roadmap] header line, exit 0
hdr=$(printf '%s\n' "$cond" | head -1)
if [ "$rc" = 0 ] && printf '%s' "$hdr" | grep -q '^\[roadmap\] '; then
  pass RRR-1
else
  fail_case RRR-1 "rc=$rc hdr=[$hdr]"
fi

# RRR-2 — header counts match the fixture
if printf '%s' "$hdr" | grep -q '1 now' \
   && printf '%s' "$hdr" | grep -q '2 next' \
   && printf '%s' "$hdr" | grep -q '1 untriaged'; then
  pass RRR-2
else
  fail_case RRR-2 "hdr=[$hdr]"
fi

# RRR-3 — NOW: section lists the now item; ★ agent-ready: section present
if printf '%s\n' "$cond" | grep -q '^NOW:' \
   && printf '%s\n' "$cond" | grep -q '#10' \
   && printf '%s\n' "$cond" | grep -q 'agent-ready:' \
   && printf '%s\n' "$cond" | grep -q '#12'; then
  pass RRR-3
else
  fail_case RRR-3 "cond=[$cond]"
fi

# RRR-4 — default view is the distinct full board (═══ rule + "Roadmap —")
if [ "$rcf" = 0 ] \
   && printf '%s\n' "$full" | grep -q '═══' \
   && printf '%s\n' "$full" | grep -q 'Roadmap —' \
   && ! printf '%s\n' "$full" | head -1 | grep -q '^\[roadmap\] '; then
  pass RRR-4
else
  fail_case RRR-4 "rcf=$rcf full(head)=$(printf '%s\n' "$full" | head -3)"
fi

# RRR-5 — unknown flag → exit 2
bash "$RENDER" --bogus >/dev/null 2>&1; rc5=$?
[ "$rc5" = 2 ] && pass RRR-5 || fail_case RRR-5 "rc=$rc5"

# RRR-6 — live mode with config but unavailable tracker emits a diagnostic
LIVE="$TMP/live"
mkdir -p "$LIVE"
git -C "$LIVE" init -q
git -C "$LIVE" config user.email f@e.com
git -C "$LIVE" config user.name f
git -C "$LIVE" commit -q --allow-empty -m seed
cat > "$LIVE/roadmap.config.yaml" <<'YAML'
profile: lean
wip_limit: 1
last_reviewed: 2020-01-01
review_cadence_weeks: 1
YAML
mkdir -p "$LIVE/.arboretum"
cat > "$LIVE/.arboretum/roadmap-pulse.json" <<'JSON'
{
  "bootstrapped_at": "2020-01-01T00:00:00Z",
  "last_maintain_run": "2020-01-01T00:00:00Z",
  "last_revise_run": "2020-01-01T00:00:00Z",
  "last_retro_completed": null,
  "nag_last_fired": {},
  "sprint_alerts_fired": {}
}
JSON
NO_GH="$TMP/no-gh"
mkdir -p "$NO_GH"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = gh ] && continue
    [ -e "$NO_GH/$_b" ] || ln -s "$_f" "$NO_GH/$_b" 2>/dev/null || true
  done
done
live_out=$(cd "$LIVE" && PATH="$NO_GH" bash "$RENDER" --condensed); rc6=$?
if [ "$rc6" = 0 ] \
   && printf '%s\n' "$live_out" | grep -qF '[nag] Strategic review overdue' \
   && printf '%s\n' "$live_out" | grep -qF '[roadmap] Configured, but tracker unavailable — check gh auth or roadmap backend settings.'; then
  pass RRR-6
else
  fail_case RRR-6 "rc=$rc6 out=[$live_out]"
fi

[ "$fail" = 0 ] && echo "roadmap-render-run contract: ALL PASS" || exit 1
