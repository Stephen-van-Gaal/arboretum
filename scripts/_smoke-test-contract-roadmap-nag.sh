#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-nag.sh — Contract test for
# docs/contracts/roadmap-nag.contract.md. Asserts RN-1..RN-4 against
# scripts/roadmap/nag.sh.
#
# nag.sh sources roadmap/lib.sh, which resolves the project root via
# git toplevel, so each case runs inside a throwaway git repo (mktemp +
# git init) carrying a fixture roadmap.config.yaml. We focus on the
# gh-INDEPENDENT nag (strategic-review-due): a shadow PATH that omits gh
# (but keeps the core tools nag.sh / lib.sh need) makes nags 2-5 skip
# deterministically, so the only line that can fire is the review nag.
#
# Note: nag.sh bootstraps the pulse on first run, seeding every
# nag_last_fired to "today" (the install-day quiet guarantee). So to let
# the weekly review nag fire we pre-seed the pulse with an OLD fire
# timestamp for strategic-review-due, which both makes bootstrap a no-op
# (file already present) and lets the 7-day weekly throttle pass.
#
# This pins the [nag] line prefix, empty-when-quiet, config-gating,
# always-exit-0, and the per-nag throttle. Picked up automatically by
# ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAG="$SCRIPT_DIR/roadmap/nag.sh"
[ -f "$NAG" ] || { echo "FAIL: $NAG not found" >&2; exit 1; }

FIX=$(mktemp -d)
NOGH_BIN=$(mktemp -d)
trap 'rm -rf "$FIX" "$NOGH_BIN"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# Shadow PATH: mirror EVERY PATH executable except gh into NOGH_BIN, so the
# gh-dependent nags (2-5) skip while every other tool stays available on any
# platform — including the transitive deps a pyenv-shim python3 shells out to
# (basename/sort/etc.), which a hand-picked allowlist would silently omit.
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = gh ] && continue
    [ -e "$NOGH_BIN/$_b" ] || ln -s "$_f" "$NOGH_BIN/$_b" 2>/dev/null || true
  done
done

git -C "$FIX" init -q

# Config with an overdue strategic review: last_reviewed is years in the
# past and the cadence is short, so days_since >> threshold regardless of
# the run date.
cat > "$FIX/roadmap.config.yaml" <<'YAML'
profile: lean
wip_limit: "1"
last_reviewed: 2020-01-01
review_cadence_weeks: "1"
YAML

# Pre-seed the pulse with an OLD strategic-review-due fire so bootstrap
# is a no-op and the weekly throttle passes (otherwise bootstrap seeds
# today's date and the review nag stays quiet — install-day guarantee).
mkdir -p "$FIX/.arboretum"
cat > "$FIX/.arboretum/roadmap-pulse.json" <<'JSON'
{
  "bootstrapped_at": "2020-01-01T00:00:00Z",
  "last_maintain_run": "2020-01-01T00:00:00Z",
  "last_revise_run": "2020-01-01T00:00:00Z",
  "last_retro_completed": null,
  "nag_last_fired": {
    "strategic-review-due": "2020-01-01T00:00:00Z",
    "maintain-overdue": "2020-01-01T00:00:00Z",
    "stale-flagged-today": "2020-01-01T00:00:00Z",
    "agent-ready-while-WIP-full": "2020-01-01T00:00:00Z",
    "profile-graduation-lean": "2020-01-01T00:00:00Z"
  },
  "sprint_alerts_fired": {}
}
JSON

run_nag() { ( cd "$FIX" && PATH="$NOGH_BIN" bash "$NAG" 2>/dev/null ); }

# RN-1 — strategic-review-due fires: exactly one [nag] line, prefixed, exit 0
out=$(run_nag); rc=$?
nlines=$(printf '%s\n' "$out" | grep -c '^\[nag\] ')
total=$(printf '%s' "$out" | grep -c .)
if [ "$rc" = 0 ] && [ "$nlines" = 1 ] && [ "$total" = 1 ] \
   && printf '%s' "$out" | grep -q 'review'; then
  pass RN-1
else
  fail_case RN-1 "rc=$rc nlines=$nlines total=$total out=[$out]"
fi

# RN-4 — immediate re-run is throttled (weekly): pulse recorded the fire
out4=$(run_nag); rc4=$?
[ "$rc4" = 0 ] && [ -z "$out4" ] && pass RN-4 || fail_case RN-4 "rc=$rc4 out=[$out4] pulse=$(cat "$FIX/.arboretum/roadmap-pulse.json" 2>/dev/null)"

# RN-2 — recent last_reviewed, no condition met → empty stdout, exit 0.
# Fresh fixture (fresh pulse) so no throttle state carries over.
FIX2=$(mktemp -d); git -C "$FIX2" init -q
cat > "$FIX2/roadmap.config.yaml" <<YAML
profile: lean
wip_limit: "1"
last_reviewed: $(date -u +%Y-%m-%d)
review_cadence_weeks: "12"
YAML
out2=$( ( cd "$FIX2" && PATH="$NOGH_BIN" bash "$NAG" 2>/dev/null ); rc=$?; echo "::rc=$rc"; ) || true
rc2=$(printf '%s' "$out2" | sed -n 's/.*::rc=\([0-9]*\)$/\1/p')
body2=$(printf '%s' "$out2" | sed 's/::rc=[0-9]*$//')
rm -rf "$FIX2"
[ "$rc2" = 0 ] && [ -z "$body2" ] && pass RN-2 || fail_case RN-2 "rc=$rc2 out=[$body2]"

# RN-3 — no roadmap.config.yaml → empty stdout, exit 0 (config-gated)
FIX3=$(mktemp -d); git -C "$FIX3" init -q
out3=$( ( cd "$FIX3" && PATH="$NOGH_BIN" bash "$NAG" 2>/dev/null ) ); rc3=$?
rm -rf "$FIX3"
[ "$rc3" = 0 ] && [ -z "$out3" ] && pass RN-3 || fail_case RN-3 "rc=$rc3 out=[$out3]"

[ "$fail" = 0 ] && echo "roadmap-nag contract: ALL PASS" || exit 1
