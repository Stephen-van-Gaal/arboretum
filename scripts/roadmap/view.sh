#!/usr/bin/env bash
# owner: roadmap
# view.sh — Shared deterministic roadmap-view core. Single renderer behind
# /roadmap view, /roadmap run, and the SessionStart banner.
#
# Two rendering families share this one script:
#   • Orientation (--format condensed|full): the fixed Done/Now/Next/Later/
#     Slack/Recommend board view. Driven by tracker state, NOT a query-spec;
#     reads no stdin. (Absorbed from the former render-run.sh.)
#   • Query (--format view, default): renders a validated query-spec —
#     fetch → filter → classify → optional epic tree → print. The model emits
#     only the query-spec; this render is the turn's final output.
#
# Modes / flags:
#   --validate-spec        read query-spec on stdin, validate, exit 0|3 (no fetch)
#   --spec-file <path>     read query-spec from file instead of stdin
#   --format full|condensed|view   render shape (default: view)
#   --quiet                fail-silent (exit 0, no output) for boot/hook path
#   --board-file <path>    test seam: open-issue JSON from file
#   --closed-file <path>   test seam: closed-issue JSON from file
#   --graph-file <path>    test seam: epic graph JSON from file
#
# Exit codes: 0 success (incl. zero-match, orientation guards, --quiet
#             degradation), 2 usage, 3 invalid query-spec, 4 tracker
#             unavailable (interactive query path only).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="render"; SPEC_FILE=""; FORMAT="view"; QUIET=false
BOARD_FILE=""; CLOSED_FILE=""; GRAPH_FILE=""
# Deterministic usage error (exit 2) when a value-flag is missing its argument,
# instead of a `set -u` unbound-variable crash (exit 1). Pass the remaining
# args: $1 is the flag, $# is how many remain.
need_val() { [ "$#" -ge 2 ] || { echo "view.sh: $1 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --validate-spec) MODE="validate"; shift ;;
    --spec-file)     need_val "$@"; SPEC_FILE="$2"; shift 2 ;;
    --format)        need_val "$@"; FORMAT="$2"; shift 2 ;;
    --quiet)         QUIET=true; shift ;;
    --board-file)    need_val "$@"; BOARD_FILE="$2"; shift 2 ;;
    --closed-file)   need_val "$@"; CLOSED_FILE="$2"; shift 2 ;;
    --graph-file)    need_val "$@"; GRAPH_FILE="$2"; shift 2 ;;
    *) echo "view.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── Query-spec validator (Python core). Reads $SPEC_JSON from the environment
#    (heredoc owns stdin, so data arrives via env, never a pipe). Prints
#    "view: invalid query-spec — <field>: <reason>" to stderr, exits 3. ──
validate_spec() {
  SPEC_JSON="$SPEC_JSON" python3 - <<'PY'
import os, sys, json
ALLOWED={"state","label_any","label_all","text_match","epic","group_by","limit"}
STATE={"open","closed","all"}; GROUP={"horizon","none"}
try:
    s=json.loads(os.environ["SPEC_JSON"])
except Exception as e:
    print(f"view: invalid query-spec — not JSON: {e}", file=sys.stderr); sys.exit(3)
if not isinstance(s, dict):
    print("view: invalid query-spec — top level must be an object", file=sys.stderr); sys.exit(3)
def die(m): print(f"view: invalid query-spec — {m}", file=sys.stderr); sys.exit(3)
for k in s:
    if k not in ALLOWED: die(f"unknown key: {k}")
if "state" in s and s["state"] not in STATE: die(f"state: not in {sorted(STATE)} (got {s['state']!r})")
if "group_by" in s and s["group_by"] not in GROUP: die(f"group_by: not in {sorted(GROUP)} (got {s['group_by']!r})")
for k in ("label_any","label_all","text_match"):
    if k in s:
        v=s[k]
        if not (isinstance(v,list) and all(isinstance(x,str) for x in v)): die(f"{k}: must be an array of strings")
if "epic" in s and s["epic"] is not None:
    if not (isinstance(s["epic"],int) and not isinstance(s["epic"],bool) and s["epic"]>0): die("epic: must be a positive integer or null")
if "limit" in s:
    v=s["limit"]
    if not (isinstance(v,int) and not isinstance(v,bool) and 1<=v<=200): die("limit: must be an integer in [1,200]")
sys.exit(0)
PY
}

# ── Orientation render (--format condensed|full) ──────────────────────
# Ported verbatim from the former render-run.sh so the SessionStart banner
# stays byte-stable. Driven by tracker state; reads no stdin. Honors
# --board-file / --closed-file test seams. Fail-soft (return 0) as the hook
# requires.
orientation_render() {
  local condensed=false
  [ "$FORMAT" = "condensed" ] && condensed=true
  local board_file="$BOARD_FILE" closed_file="$CLOSED_FILE"
  local wip_limit=1 nag_output="" CONFIG

  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"

  if [ -z "$board_file" ]; then
    CONFIG="$(roadmap_config_path)" || true
    [ -z "$CONFIG" ] && return 0
    wip_limit=$(roadmap_config_get wip_limit 2>/dev/null || echo 1)
    nag_output="$(bash "$SCRIPT_DIR/nag.sh" 2>/dev/null || true)"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    if [ -z "$board_file" ]; then
      printf '[roadmap] Configured, but renderer dependencies are missing — jq unavailable.\n'
      return 0
    fi
    echo "roadmap: jq required" >&2
    return 1
  fi

  local open_json closed_json
  if [ -n "$board_file" ]; then
    open_json="$(cat "$board_file")"
  else
    if ! roadmap_require_backend >/dev/null 2>&1; then
      [ -n "$nag_output" ] && printf '%s\n' "$nag_output"
      printf '[roadmap] Configured, but tracker unavailable — check gh auth or roadmap backend settings.\n'
      return 0
    fi
    open_json="$(roadmap_tracker_issue_list --state open --limit 200 \
      --json number,title,labels,updatedAt,milestone 2>/dev/null || echo '[]')"
  fi

  if [ -n "$closed_file" ]; then
    closed_json="$(cat "$closed_file")"
  elif [ -z "$board_file" ]; then
    closed_json="$(roadmap_tracker_issue_list --state closed --limit 50 \
      --json number,title,closedAt --search "closed:>$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)" 2>/dev/null || echo '[]')"
  else
    closed_json='[]'
  fi

  local wip_count=0
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    wip_count="$(git worktree list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  fi

  local now_list next_list later_list slack_list untriaged_count agent_ready_list
  now_list=$(echo "$open_json" | jq -r '
    [.[] | select(any(.labels[]; .name == "horizon:now"))] | sort_by(.number)
    | .[] | "\(.number)\t\(.title)"')
  next_list=$(echo "$open_json" | jq -r '
    [.[] | select(any(.labels[]; .name == "horizon:next"))] | sort_by(.number)
    | .[] | "\(.number)\t\(.title)"')
  later_list=$(echo "$open_json" | jq -r '
    [.[] | select(any(.labels[]; .name == "horizon:later"))] | sort_by(.number) | reverse
    | .[] | "\(.number)\t\(.title)"')
  slack_list=$(echo "$open_json" | jq -r '
    [.[] | select(any(.labels[]; .name == "type:docs" or .name == "type:chore"))] | sort_by(.number) | reverse
    | .[] | "\(.number)\t\(.title)\t\(.labels | map(select(.name == "type:docs" or .name == "type:chore")) | first.name)"')
  untriaged_count=$(echo "$open_json" | jq '
    [.[] | select(any(.labels[]; .name | startswith("horizon:")) | not)] | length')
  agent_ready_list=$(echo "$open_json" | jq -r '
    [.[] | select(any(.labels[]; .name == "agent-ready"))] | sort_by(.number)
    | .[] | "\(.number)\t\(.title)"')

  local total_open now_count next_count later_count
  total_open=$(echo "$open_json" | jq 'length')
  count_lines() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }
  now_count=$(count_lines "$now_list")
  next_count=$(count_lines "$next_list")
  later_count=$(count_lines "$later_list")

  # ── Condensed (SessionStart hook block) ──
  if $condensed; then
    printf '[roadmap] %d open · %d now · %d next · %d later · %d untriaged · WIP: %d\n' \
      "$total_open" "$now_count" "$next_count" "$later_count" "$untriaged_count" "$wip_count"
    if [ "$now_count" -gt 0 ]; then
      printf '\nNOW:\n'
      printf '%s\n' "$now_list" | head -3 | while IFS=$'\t' read -r n t; do
        [ -z "$n" ] && continue; printf '  #%s  %s\n' "$n" "$t"
      done
    fi
    if [ -n "$agent_ready_list" ]; then
      printf '\n★ agent-ready:\n'
      printf '%s\n' "$agent_ready_list" | head -3 | while IFS=$'\t' read -r n t; do
        [ -z "$n" ] && continue; printf '  #%s  %s\n' "$n" "$t"
      done
    fi
    if [ "$untriaged_count" -ge 5 ]; then
      printf '\n  → /roadmap maintain has %d untriaged\n' "$untriaged_count"
    fi
    return 0
  fi

  # ── Full (interactive board view) ──
  local sep="═══════════════════════════════════════════════════════════════════════"
  echo "$sep"
  printf '  Roadmap — %d open · %d now · %d next · %d later · WIP: %d/%d\n' \
    "$total_open" "$now_count" "$next_count" "$later_count" "$wip_count" "$wip_limit"
  echo "$sep"

  local done_count
  done_count=$(echo "$closed_json" | jq 'length')
  if [ "$done_count" -gt 0 ]; then
    echo; echo "DONE  (last 7 days)"
    echo "$closed_json" | jq -r '.[] | "  #\(.number)  \(.title)  \(.closedAt[0:10])"' | head -5
  fi

  echo
  printf 'NOW  (%d/%d WIP)\n' "$wip_count" "$wip_limit"
  if [ -n "$now_list" ]; then
    printf '%s\n' "$now_list" | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue; printf '  #%s  %s\n' "$n" "$t"
    done
  else
    echo "  (nothing in flight)"
  fi

  echo; printf 'NEXT\n'
  if [ -n "$next_list" ]; then
    printf '%s\n' "$next_list" | head -10 | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue; printf '  #%s  %s\n' "$n" "$t"
    done
  else
    echo "  (queue empty — run /roadmap maintain to surface candidates)"
  fi

  if [ -n "$agent_ready_list" ]; then
    echo; echo 'AGENT-READY (parallel pickup via /start <n>)'
    printf '%s\n' "$agent_ready_list" | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue; printf '  ★ #%s  %s\n' "$n" "$t"
    done
  fi

  if [ "$later_count" -gt 0 ]; then
    echo; printf 'LATER  (top 5 of %d)\n' "$later_count"
    printf '%s\n' "$later_list" | head -5 | while IFS=$'\t' read -r n t; do
      [ -z "$n" ] && continue; printf '  #%s  %s\n' "$n" "$t"
    done
  fi

  echo; echo 'SLACK  (parallel-safe alongside WIP)'
  if [ "$untriaged_count" -ge 3 ]; then
    printf '  /roadmap maintain  ← %d untriaged\n' "$untriaged_count"
  fi
  if [ -n "$slack_list" ]; then
    printf '%s\n' "$slack_list" | head -3 | while IFS=$'\t' read -r n t l; do
      [ -z "$n" ] && continue; printf '  #%s  %s  [%s]\n' "$n" "$t" "$l"
    done
  fi

  echo; echo "$sep"; echo "RECOMMEND"
  if [ "$wip_count" -ge 1 ] && [ "$now_count" -eq 0 ] && [ "$total_open" -gt 0 ]; then
    echo "  • You have a worktree but no horizon:now issue. Identify the in-flight"
    echo "    issue and apply horizon:now (or run /roadmap maintain to triage)."
  elif [ "$wip_count" -ge 1 ] && [ "$now_count" -ge 1 ]; then
    echo "  • You have work in flight — finish before starting another."
  elif [ "$now_count" -gt 0 ]; then
    echo "  • Pick up a horizon:now item to get started."
  elif [ "$next_count" -gt 0 ]; then
    echo "  • No horizon:now items — promote from NEXT or run /roadmap maintain."
  elif [ "$untriaged_count" -ge 3 ]; then
    echo "  • $untriaged_count untriaged issues — run /roadmap maintain to triage them"
    echo "    (Phase 2; for now, manually apply horizon:* labels)."
  elif [ "$total_open" -eq 0 ]; then
    echo "  • Empty board — capture new work with /idea."
  else
    echo "  • Board has open issues but none in horizon:now/next/later — triage needed."
  fi
  [ -n "$agent_ready_list" ] && echo "  • ★ agent-ready items can be delegated to a subagent in parallel."
  echo "$sep"
  [ -n "$nag_output" ] && printf '\n%s\n' "$nag_output"
  return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────
# validate-spec: reads stdin, validates, exits.
if [ "$MODE" = "validate" ]; then
  if [ -n "$SPEC_FILE" ]; then SPEC_JSON="$(cat "$SPEC_FILE")"; else SPEC_JSON="$(cat)"; fi
  validate_spec; exit $?
fi

# Orientation formats are query-spec-free and read no stdin.
if [ "$FORMAT" = "condensed" ] || [ "$FORMAT" = "full" ]; then
  orientation_render
  exit 0
fi

# ── Query path (--format view) ────────────────────────────────────────
if [ -n "$SPEC_FILE" ]; then SPEC_JSON="$(cat "$SPEC_FILE")"; else SPEC_JSON="$(cat)"; fi
validate_spec || { [ "$QUIET" = true ] && exit 0; exit 3; }

# The query path depends on jq for spec extraction, counting, and render.
# roadmap_require_backend does not require jq on the GitHub backend, so guard
# here with a controlled diagnostic rather than a bare `jq: command not found`.
if ! command -v jq >/dev/null 2>&1; then
  [ "$QUIET" = true ] && exit 0
  echo "[roadmap view] jq is required for --format view but was not found." >&2
  exit 4
fi

spec_get() { printf '%s' "$SPEC_JSON" | jq -r "$1"; }
STATE=$(spec_get '.state // "open"')
LIMIT=$(spec_get '.limit // 50')

# ── Epic-tree mode: render one epic + its children (group_by:epic deferred) ──
EPIC=$(spec_get '.epic // empty')
if [ -n "$EPIC" ]; then
  if [ -n "$GRAPH_FILE" ]; then
    GRAPH="$(cat "$GRAPH_FILE")"
  else
    # shellcheck source=lib.sh
    source "$SCRIPT_DIR/lib.sh"
    GRAPH="$(roadmap_epic_graph "$EPIC" 2>/dev/null)" || GRAPH='{"next_up":null,"nodes":{}}'
  fi
  GRAPH_JSON="$GRAPH" EPIC="$EPIC" python3 - <<'PY'
import os, json
g=json.loads(os.environ["GRAPH_JSON"]); nodes=g.get("nodes",{}); root=str(os.environ["EPIC"])
e=nodes.get(root)
if not e:
    print("no matches: epic not found or has no linked children."); raise SystemExit(0)
kids=[nodes[str(c)] for c in e.get("children",[]) if str(c) in nodes]
done=sum(1 for k in kids if k.get("state")=="closed")
def hz(n):
    for l in n.get("labels",[]):
        if isinstance(l,str) and l.startswith("horizon:"): return "  ["+l+"]"
    return ""
print(f"▸ #{e['number']}  {e['title']}{hz(e)}   {len(kids)-done} open · {done} done · {len(kids)} total")
for j,k in enumerate(kids):
    b="└─" if j==len(kids)-1 else "├─"
    mark=" ✓" if k.get("state")=="closed" else ""
    print(f"    {b} #{k['number']}  {k['title']}{hz(k)}{mark}")
PY
  exit 0
fi

# ── Fetch open issues: test seam (--board-file) or live (lib.sh) ──────
if [ -n "$BOARD_FILE" ]; then
  BOARD="$(cat "$BOARD_FILE")"
else
  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"
  if ! roadmap_require_backend >/dev/null 2>&1; then
    [ "$QUIET" = true ] && exit 0
    echo "[roadmap view] Configured, but tracker unavailable — check gh auth or roadmap backend settings." >&2
    exit 4
  fi
  # Do NOT pre-filter by label_any at the tracker level: label_any is OR
  # semantics, but a comma-joined `--label` is AND on GitHub and a single
  # tag-CONTAINS on the ADO adapter — either silently drops valid matches.
  # The Python post-filter below applies the correct ANY/ALL semantics.
  #
  # Fetch a fixed window (not the spec's limit): the label/text filters run
  # AFTER the fetch, so limiting the fetch would drop matches beyond the window.
  # `limit` is the max *results shown*, applied to the filtered set below.
  list_args=(--state "$STATE" --limit 200 --json "number,title,state,labels")
  BOARD="$(roadmap_tracker_issue_list "${list_args[@]}" 2>/dev/null)" || BOARD="[]"
fi

# ── Filter in Python: label_any / label_all / text_match (title, ANY term) ──
# Data passed via env vars — never interpolated into a command — so untrusted
# text_match terms cannot inject.
FILTERED="$(BOARD_JSON="$BOARD" SPEC_JSON="$SPEC_JSON" python3 - <<'PY'
import os, json
board=json.loads(os.environ["BOARD_JSON"])
spec=json.loads(os.environ["SPEC_JSON"])
terms=[t.lower() for t in spec.get("text_match",[])]
label_any=set(spec.get("label_any",[]))
label_all=set(spec.get("label_all",[]))
def labels(i): return {l["name"] for l in (i.get("labels") or [])}
def ok(i):
    title=(i.get("title") or "").lower()
    if terms and not any(t in title for t in terms): return False
    if label_any and not (label_any & labels(i)): return False
    if label_all and not label_all.issubset(labels(i)): return False
    return True
print(json.dumps([i for i in board if ok(i)]))
PY
)"

COUNT=$(printf '%s' "$FILTERED" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
  echo "no matches for the current filter."
  exit 0
fi

# ── Render: flat (group_by:none) or bucketed by horizon (group_by:horizon) ──
GROUP_BY=$(spec_get '.group_by // "none"')
FILTERED_JSON="$FILTERED" GROUP_BY="$GROUP_BY" LIMIT="$LIMIT" python3 - <<'PY'
import os, json
items=json.loads(os.environ["FILTERED_JSON"])
# limit = max results shown (applied AFTER filtering, not as a fetch cap).
try: items=items[:int(os.environ.get("LIMIT","50"))]
except (TypeError, ValueError): pass
group=os.environ.get("GROUP_BY","none")
def hz(i):
    for l in (i.get("labels") or []):
        if l["name"].startswith("horizon:"): return l["name"]
    return None
def line(i):
    h=hz(i); tag=f"   [{h}]" if h else ""
    return f"  #{i['number']}  {i['title']}{tag}"
if group=="horizon":
    order=["horizon:now","horizon:next","horizon:later"]
    buckets={}
    for i in items: buckets.setdefault(hz(i) or "horizon:unset",[]).append(i)
    for h in order+[k for k in buckets if k not in order]:
        if h in buckets:
            print(f"\n▸ {h}")
            for i in buckets[h]: print("  "+line(i).strip())
else:
    for i in items: print(line(i))
PY
exit 0
