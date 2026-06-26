#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# ci-parallel: safe
# Smoke test for scripts/roadmap/score-render.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$SCRIPT_DIR/roadmap/score-render.sh"; fail=0
tmpc="$(mktemp)"
cat > "$tmpc" <<'EOF'
{"5":{"value":"high","value_description":"a","complexity":"bugfix","blocker":"none","disposition":"keep","class":"work-unit"},
 "6":{"value":"low","value_description":"b","complexity":"design","blocker":"spec","disposition":"combine","anchor":7,"priority_driver":5,"class":"work-unit"}}
EOF
out="$(bash "$SR" --cache "$tmpc")"
echo "$out" | grep -q '#5' && echo "ok - lists #5" || { echo "FAIL - #5"; fail=1; }
echo "$out" | grep -qi 'AGENT-READY' && echo "$out" | grep -A3 'AGENT-READY' | grep -q '5' && echo "ok - 5 in agent-ready" || { echo "FAIL - agent-ready"; fail=1; }
echo "$out" | grep -qi 'COMBINE' && echo "ok - combine section" || { echo "FAIL - combine"; fail=1; }
# #5 (high) must sort above #6 (low)
[ "$(echo "$out" | grep -nE '#5|#6' | head -1 | grep -c '#5')" = "1" ] && echo "ok - high sorts first" || { echo "FAIL - sort"; fail=1; }
rm -f "$tmpc"; exit $fail
