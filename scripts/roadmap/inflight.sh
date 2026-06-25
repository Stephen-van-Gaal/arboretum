#!/usr/bin/env bash
# owner: inflight-work-classifier
# scope: plugin-only
# inflight.sh — in-flight-work classifier. Finds & classifies all open board
# work into epic / sub-issue / naked issue and emits one classified-board JSON.
# See docs/contracts/inflight-classifier.contract.md and the design spec
# docs/superpowers/specs/2026-06-09-inflight-work-classifier-design.md
#
# Modes:
#   --graph-file <path> --signals-file <path>   test seams (no network)
#   --signals-stdin                             local-signal parse (reads branch
#                                               names on stdin; emits issue nums)
#   (live)                                      builds graph via lib.sh + local git
#
# Filter flags: --me / --unassigned (+ --viewer <handle> test seam).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/scrub-control-chars.sh"

# Emit the set of issue numbers that have a local branch or worktree.
# Topic = branch name after the prefix; leading \d+ is the issue number.
# Reads branch names on stdin (one per line). Pure text — no network.
_inflight_parse_signals() {
  { grep -oE '(feat|fix|docs|chore)/[0-9]+' || true; } \
    | { grep -oE '[0-9]+$' || true; } \
    | sort -u
}

# Emit issue numbers correlated to a local git branch or worktree. No network.
inflight_local_signals() {
  { git branch --format='%(refname:short)' 2>/dev/null || true
    git worktree list 2>/dev/null | awk '{print $NF}' || true; } \
    | _inflight_parse_signals
}

if [ "${1:-}" = "--signals-stdin" ]; then
  # test seam: read branch names from stdin instead of git
  _inflight_parse_signals
  exit 0
fi

# classify_board core: board graph + local-signal set → the classified-board
# JSON seam. The python primitives are single-sourced in _classify_core.py;
# CLASSIFY_CORE_DIR bridges the script dir for the import (stdin heredoc has no
# __file__). FILTER/VIEWER (when set) apply the --me/--unassigned filter.
inflight_classify() {
  local graph_file="$1" signals_file="$2"
  CLASSIFY_CORE_DIR="$SCRIPT_DIR" SIGNALS_FILE="$signals_file" \
  FILTER="${FILTER:-}" VIEWER="${VIEWER:-}" \
  python3 - "$graph_file" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["CLASSIFY_CORE_DIR"])
from _classify_core import scrub, is_active, is_blocked, epic_of, classify_epic  # noqa: E402


def scrub_list(xs):
    return [scrub(x) for x in (xs or [])]


with open(sys.argv[1], encoding="utf-8") as fh:
    g = json.load(fh)
nodes = {int(k): v for k, v in g["nodes"].items()}
degraded = bool(g.get("degraded", False))

sig_nums = set()
sf = os.environ.get("SIGNALS_FILE", "")
if sf and os.path.exists(sf):
    with open(sf, encoding="utf-8") as fh:
        sig_nums = {int(x) for x in fh.read().split() if x.strip().isdigit()}


def signal(n):
    if is_active(n):
        return "stage:" + n["stage"].lstrip("/")
    if n.get("has_open_pr"):
        return "pr"
    if n["number"] in sig_nums:
        return "branch"
    return None


def child_class(n):
    if is_active(n):
        return "active"
    if is_blocked(n):
        return "blocked"
    return "ready"


# epics: board-wide, included iff >=1 child done OR >=1 child active
epics = []
for num, n in nodes.items():
    if not n.get("is_epic"):
        continue
    kids = [nodes[c] for c in n.get("children", []) if c in nodes]
    done = [k for k in kids if k["state"] == "closed"]
    openk = [k for k in kids if k["state"] == "open"]
    if not (done or any(is_active(k) for k in openk)):
        continue
    e = classify_epic(nodes, num)
    e["author"] = scrub(n.get("author"))
    e["sub_issues"] = [
        {"number": k["number"], "title": scrub(k["title"]),
         "class": child_class(k), "signal": signal(k),
         "assignees": scrub_list(k.get("assignees", [])), "author": scrub(k.get("author"))}
        for k in openk
    ]
    epics.append(e)
epics.sort(key=lambda e: e["number"])

# naked: in-flight, no epic ancestor, not an epic itself
naked = []
for num, n in nodes.items():
    if n["state"] != "open" or n.get("is_epic"):
        continue
    if epic_of(nodes, num) is not None:
        continue
    s = signal(n)
    if s is None:
        continue
    naked.append({"number": num, "title": scrub(n["title"]), "signal": s,
                  "assignees": scrub_list(n.get("assignees", [])), "author": scrub(n.get("author"))})
naked.sort(key=lambda x: x["number"])

# --me / --unassigned filter (epic header counts done/total stay unfiltered).
filt = os.environ.get("FILTER") or None
viewer = os.environ.get("VIEWER") or None


def keep(node):
    a = node.get("assignees", [])
    if filt == "unassigned":
        return not a
    if filt == "me":
        return viewer in a
    return True


if filt:
    naked = [n for n in naked if keep(n)]
    kept = []
    for e in epics:
        subs = [s for s in e["sub_issues"] if keep(s)]
        if subs:                      # done/total stay unfiltered
            e2 = dict(e)
            e2["sub_issues"] = subs
            e2["active"] = [a for a in e["active"] if any(s["number"] == a["number"] for s in subs)]
            kept.append(e2)
    epics = kept

print(json.dumps({"epics": epics, "naked_issues": naked, "degraded": degraded,
                  "viewer": viewer, "filter": filt}, indent=2))
PY
}

# Argument parsing: test seams + filter flags.
GRAPH_FILE=""
SIGNALS_FILE=""
FILTER=""
VIEWER=""
_VIEWER_SET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --graph-file)   GRAPH_FILE="$2"; shift 2 ;;
    --signals-file) SIGNALS_FILE="$2"; shift 2 ;;
    --me)           FILTER="me"; shift ;;
    --unassigned)   FILTER="unassigned"; shift ;;
    --viewer)       VIEWER="$2"; _VIEWER_SET=true; shift 2 ;;
    *) echo "inflight: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --me requires a resolvable viewer. In --graph-file mode there is no live
# resolver, so an empty VIEWER here (explicit --viewer "" OR --me with no
# --viewer at all) is an unresolvable-identity signal: fail loud, no board
# (anti-silent-failure). Live mode resolves VIEWER below before this can bite.
if [ "$FILTER" = "me" ] && [ -z "$VIEWER" ] && { [ "$_VIEWER_SET" = "true" ] || [ -n "$GRAPH_FILE" ]; }; then
  echo "inflight: cannot resolve current user for --me" >&2
  exit 3
fi

export FILTER VIEWER
if [ -n "$GRAPH_FILE" ]; then
  inflight_classify "$GRAPH_FILE" "$SIGNALS_FILE"
  exit 0
fi

# ── Live mode ─────────────────────────────────────────────────────────
# No --graph-file: build the board graph via lib.sh + local git signals, then
# classify. Fail-soft: any fetch failure degrades to a partial (or empty) board
# with degraded:true and exit 0 — the engine never crashes a consumer.
# INFLIGHT_LIB is a test seam to inject a fake lib (no network).
_INFLIGHT_LIB="${INFLIGHT_LIB:-$SCRIPT_DIR/lib.sh}"
# shellcheck source=/dev/null
. "$_INFLIGHT_LIB"

# --me needs a resolvable viewer. In live mode (no explicit --viewer) resolve it
# via roadmap_current_user; on failure exit loud with no board (anti-silent).
if [ "$FILTER" = "me" ] && [ "$_VIEWER_SET" = "false" ]; then
  if VIEWER="$(roadmap_current_user 2>/dev/null)" && [ -n "$VIEWER" ]; then
    export VIEWER
  else
    echo "inflight: cannot resolve current user for --me" >&2
    exit 3
  fi
fi

_graph_file=$(mktemp)
_signals_file=$(mktemp)
trap 'rm -f "$_graph_file" "$_signals_file"' EXIT

if ! roadmap_inflight_board_graph > "$_graph_file" 2>/dev/null || [ ! -s "$_graph_file" ]; then
  printf '%s\n' '{"nodes":{},"degraded":true}' > "$_graph_file"
fi
inflight_local_signals > "$_signals_file" 2>/dev/null || : > "$_signals_file"

if ! inflight_classify "$_graph_file" "$_signals_file"; then
  # Total failure (e.g. malformed graph) → honest empty degraded board, exit 0.
  printf '%s\n' '{"epics":[],"naked_issues":[],"degraded":true,"viewer":null,"filter":null}'
fi
exit 0
