#!/usr/bin/env bash
# owner: inflight-work-classifier
# epic-walk.sh — Read-only epic resolver. Emits epics_in_flight + auto_advance
# candidate as JSON on stdout. Native sub-issue linkage only (no body parsing).
#
# Modes:
#   --graph-file <path>   read a pre-built graph JSON (test seam; no network)
#   --next-up <N>         live mode: fetch graph for issue N via lib.sh (fail-soft)
#
# Output (docs/contracts/epic-walk.contract.md):
#   { "epics_in_flight": [ {number,title,done,total,active[],next|null,blocked[]} ],
#     "auto_advance": null | {from,to,epic} }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/scrub-control-chars.sh"

GRAPH_FILE=""
NEXT_UP_ARG=""
_LIVE_MODE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --graph-file) GRAPH_FILE="$2"; shift 2 ;;
    --next-up)    NEXT_UP_ARG="$2"; _LIVE_MODE=true; shift 2 ;;
    *) echo "epic-walk: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$_LIVE_MODE" = "false" ] && [ -z "$GRAPH_FILE" ]; then
  echo "epic-walk: missing --graph-file or --next-up" >&2
  exit 2
fi

if [ -z "$GRAPH_FILE" ]; then
  # Live mode: fetch graph via lib.sh, write to a temp file, use as graph file.
  # Fail-soft: on any fetch error emit empty result and exit 0 (never crash boot path).
  # shellcheck source=scripts/roadmap/lib.sh
  . "$SCRIPT_DIR/lib.sh"
  graph=$(roadmap_epic_graph "${NEXT_UP_ARG:-}" 2>/dev/null) \
    || graph='{"next_up":null,"nodes":{}}'
  [ -n "$graph" ] || graph='{"next_up":null,"nodes":{}}'
  GRAPH_FILE=$(mktemp)
  printf '%s' "$graph" > "$GRAPH_FILE"
  trap 'rm -f "$GRAPH_FILE"' EXIT
fi
[ -f "$GRAPH_FILE" ] || { echo "epic-walk: graph file not found: $GRAPH_FILE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "epic-walk: python3 required" >&2; exit 2; }

# Run the python core; in live mode any failure degrades to empty result (exit 0).
# The classification primitives are single-sourced in _classify_core.py; the
# python here runs over stdin (no __file__), so the script dir is bridged via
# CLASSIFY_CORE_DIR for the import.
_py_out=$(CLASSIFY_CORE_DIR="$SCRIPT_DIR" python3 - "$GRAPH_FILE" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["CLASSIFY_CORE_DIR"])
from _classify_core import (  # noqa: E402
    DEPTH_CAP, scrub, is_active, is_blocked, epic_of, is_epic_complete, classify_epic,
)

with open(sys.argv[1], encoding="utf-8") as fh:
    g = json.load(fh)
nodes = {int(k): v for k, v in g["nodes"].items()}
next_up = g.get("next_up")

# Inclusion: epics with >=1 active child, plus parent-of-next-up.
in_flight_nums = set()
for num, n in nodes.items():
    if n["state"] == "open" and is_active(n):
        e = epic_of(nodes, num)
        if e is not None:
            in_flight_nums.add(e)
if next_up is not None and next_up in nodes:
    e = epic_of(nodes, next_up)
    if e is not None:
        in_flight_nums.add(e)

epics = [classify_epic(nodes, e) for e in sorted(in_flight_nums)]

# Auto-advance candidate: next-up closed → walk up the epic chain until an epic
# with a ready next child is found (bounded by DEPTH_CAP + visited-set).
auto = None
if next_up is not None and next_up in nodes and nodes[next_up]["state"] == "closed":
    # depth counts climbs (not the initial epic eval), so up to DEPTH_CAP+1 epics are visited.
    cur, depth, seen = epic_of(nodes, next_up), 0, set()
    while cur is not None and depth < DEPTH_CAP and cur not in seen:
        seen.add(cur)
        ec = classify_epic(nodes, cur)
        if ec["next"] is not None:
            auto = {"from": next_up, "to": ec["next"]["number"], "epic": cur}
            break
        # this epic is complete (or all-blocked) — climb to its parent epic
        parent_num = nodes[cur].get("parent")
        cur = epic_of(nodes, parent_num) if parent_num is not None else None
        depth += 1

print(json.dumps({"epics_in_flight": epics, "auto_advance": auto}, indent=2))
PY
) || {
  if [ "$_LIVE_MODE" = "true" ]; then
    printf '%s\n' '{"epics_in_flight": [], "auto_advance": null}'
    exit 0
  fi
  exit 1
}
printf '%s\n' "$_py_out"
