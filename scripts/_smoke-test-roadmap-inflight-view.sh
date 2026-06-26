#!/usr/bin/env bash
# owner: roadmap-inflight-view
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-roadmap-inflight-view.sh — unit coverage for the in-flight board
# render in view.sh (--format full), driven by the --inflight-file + --board-file
# seams. Fixture-driven; no network. Picked up by ci-checks.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$SCRIPT_DIR/roadmap/view.sh"
FIX="$SCRIPT_DIR/../tests/fixtures/roadmap-inflight-view"
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; fail=1; }

render() {
  bash "$VIEW" --format full \
    --board-file "$FIX/board.json" \
    --closed-file "$FIX/closed.json" \
    --inflight-file "$1"
}

# RV-1: --inflight-file is accepted (not an "unknown arg" usage error).
out="$(render "$FIX/classified-full.json")"; rc=$?
[ "$rc" -eq 0 ] && pass "RV-1 --inflight-file accepted" || failc "RV-1 exit=$rc" "$out"

out="$(render "$FIX/classified-full.json")"

# RV-2: in-flight ISSUES section, no cap, with signal tags.
echo "$out" | grep -q "IN FLIGHT — ISSUES" \
  && echo "$out" | grep -qE "#624 .*\[stage:design\]" \
  && echo "$out" | grep -qE "#305 .*\[pr\]" \
  && echo "$out" | grep -qE "#671 .*\[branch\]" \
  && pass "RV-2 in-flight issues + signals" || failc "RV-2" "$out"

# RV-3: in-flight EPICS section with done/total + active marker.
echo "$out" | grep -q "IN FLIGHT — EPICS" \
  && echo "$out" | grep -qE "▸ #516 .*1/3" \
  && echo "$out" | grep -qE "active #677" \
  && pass "RV-3 in-flight epics + progress + markers" || failc "RV-3" "$out"

# RV-4: in-flight sections come BEFORE the NOW bucket.
ln_inflight=$(echo "$out" | grep -n "IN FLIGHT — ISSUES" | head -1 | cut -d: -f1)
ln_now=$(echo "$out" | grep -n "^NOW" | head -1 | cut -d: -f1)
[ -n "$ln_inflight" ] && [ -n "$ln_now" ] && [ "$ln_inflight" -lt "$ln_now" ] \
  && pass "RV-4 in-flight-first ordering" || failc "RV-4 inflight=$ln_inflight now=$ln_now" "$out"

out="$(render "$FIX/classified-full.json")"

# RV-5: a number shown in-flight is suppressed from its horizon bucket row.
#       #624 (horizon:now, naked in-flight) must NOT appear as a NOW row, but
#       #174 (horizon:now, not in-flight) must remain.
now_block="$(echo "$out" | awk '/^NOW/{f=1;next} /^NEXT/{f=0} f')"
! echo "$now_block" | grep -qE "#624 " \
  && echo "$now_block" | grep -qE "#174 " \
  && pass "RV-5 de-dup: in-flight #624 suppressed from NOW, #174 kept" \
  || failc "RV-5" "$now_block"

# RV-6 (VD4a): header counts stay RAW — the header still counts #624 as a now item.
echo "$out" | grep -qE "Roadmap — .* 3 now" \
  && pass "RV-6 header counts unfiltered (VD4a)" || failc "RV-6" "$(echo "$out" | head -3)"

out="$(render "$FIX/classified-full.json")"
# RV-7: DONE renders AFTER SLACK and before RECOMMEND (D5 tail).
ln_slack=$(echo "$out" | grep -n "^SLACK" | head -1 | cut -d: -f1)
ln_done=$(echo "$out" | grep -n "^DONE" | head -1 | cut -d: -f1)
ln_rec=$(echo "$out" | grep -n "RECOMMEND" | head -1 | cut -d: -f1)
[ -n "$ln_done" ] && [ "$ln_slack" -lt "$ln_done" ] && [ "$ln_done" -lt "$ln_rec" ] \
  && pass "RV-7 DONE moved to tail" || failc "RV-7 slack=$ln_slack done=$ln_done rec=$ln_rec" "$out"

# RV-8: malformed/failed classifier → horizon-only board + ONE notice, exit 0, no crash.
out="$(render "$FIX/classified-malformed.json")"; rc=$?
[ "$rc" -eq 0 ] \
  && ! echo "$out" | grep -q "IN FLIGHT" \
  && echo "$out" | grep -qiE "in-flight view unavailable" \
  && echo "$out" | grep -qE "#624 " \
  && pass "RV-8 classifier failure → horizon-only + notice (no crash)" \
  || failc "RV-8 rc=$rc" "$out"

# RV-9: degraded board → render in-flight + ONE partial notice.
out="$(render "$FIX/classified-degraded.json")"
echo "$out" | grep -q "IN FLIGHT — ISSUES" \
  && echo "$out" | grep -qiE "partial board" \
  && pass "RV-9 degraded → render + partial notice" || failc "RV-9" "$out"

# RV-10: author-controlled titles are scrubbed of ESC bytes at the consumer.
out="$(render "$FIX/classified-hostile-title.json")"
if printf '%s' "$out" | LC_ALL=C grep -q $'\x1b'; then
  failc "RV-10 ESC byte survived into render" "$out"
else
  echo "$out" | grep -q "pwn" && pass "RV-10 title scrubbed (no ESC, text preserved)" || failc "RV-10 text lost" "$out"
fi

# RV-11: the author-derived `signal` field is ALSO scrubbed at the consumer
#        (B4 finding — defense-in-depth covers every rendered string, not just title).
out="$(render "$FIX/classified-hostile-signal.json")"
if printf '%s' "$out" | LC_ALL=C grep -q $'\x1b'; then
  failc "RV-11 ESC byte survived via signal" "$out"
else
  echo "$out" | grep -qE "#998 .*stage:.*PWN" \
    && pass "RV-11 signal scrubbed (no ESC, text preserved)" || failc "RV-11 signal text lost" "$out"
fi

# RV-12: a non-int `number` in a hostile board must NOT crash/silently drop the
#        in-flight section (B4 finding — suppress-set sort is string-keyed).
out="$(render "$FIX/classified-badnumber.json")"; rc=$?
[ "$rc" -eq 0 ] \
  && echo "$out" | grep -q "IN FLIGHT — ISSUES" \
  && pass "RV-12 non-int number renders, no crash/silent-drop" || failc "RV-12 rc=$rc" "$out"

# RV-13: bucket caps apply AFTER suppression, not before (Copilot review). With
#        the top-3 SLACK items (804/803/802) in-flight (suppressed), the
#        non-suppressed #801 below the head -3 cap must still render — capping the
#        raw list first would drop it and show an empty SLACK.
out="$(bash "$VIEW" --format full --board-file "$FIX/board-capbug.json" \
        --closed-file "$FIX/closed.json" --inflight-file "$FIX/classified-capbug.json")"
slack_block="$(echo "$out" | awk '/^SLACK/{f=1;next} /^DONE|RECOMMEND|═/{f=0} f')"
echo "$slack_block" | grep -qE "#801 " \
  && pass "RV-13 cap applied after suppression (non-suppressed #801 below cap renders)" \
  || failc "RV-13 SLACK under-filled by cap-before-suppress" "$slack_block"

# RV-14: the condensed (SessionStart) path ignores --inflight-file entirely —
#        no in-flight fetch/sections even when one is passed (Copilot perf finding).
out="$(bash "$VIEW" --format condensed --board-file "$FIX/board.json" \
        --inflight-file "$FIX/classified-full.json" 2>&1)"
! echo "$out" | grep -qiE "IN FLIGHT|in-flight view unavailable|partial board" \
  && pass "RV-14 condensed path ignores in-flight fetch" || failc "RV-14 condensed leaked in-flight" "$out"

exit $fail
