#!/usr/bin/env bash
# owner: token-accounting
# read-session-journey.sh — per-stage/skill/subagent token cost from a transcript.
# Bash senses the environment (rates, config, descriptor); python is a pure
# function of its inputs. Zero LLM inference. See token-journey design spec D1–D10.
# The renderer core lives in scripts/lib/journey_render.py (slice-1 DS1.1) and is
# shared with render-ledger-journey.sh (push-ledger path). This is the
# transcript/audit path — its behaviour is unchanged by the extraction.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/token-rates.sh"
. "$ROOT/scripts/lib/state-dir.sh"
. "$ROOT/scripts/lib/scrub-control-chars.sh"

transcript=""; to_stdout=0; output_dir=""; descriptor=""; fmt="md"
while [ $# -gt 0 ]; do case "$1" in
  --transcript) transcript="$2"; shift 2;;
  --stdout) to_stdout=1; shift;;
  --output-dir) output_dir="$2"; shift 2;;
  --descriptor) descriptor="$2"; shift 2;;
  --format) fmt="$2"; shift 2;;
  *) shift;; esac; done
[ -n "$transcript" ] || { echo "usage: read-session-journey.sh --transcript <file.jsonl> [--stdout] [--output-dir D] [--descriptor X] [--format md|json]" >&2; exit 2; }
[ -f "$transcript" ] || { echo "read-session-journey.sh: transcript not found: $transcript" >&2; exit 2; }
# Default base anchors at the main checkout, not the invoking worktree (#673).
[ -n "$output_dir" ] || output_dir="$(arboretum_state_dir)/token-journey"

# Descriptor cascade (local-first; session-id from the transcript filename always wins last).
if [ -z "$descriptor" ]; then
  pr="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  if pr_num="$(gh pr view --json number -q .number 2>/dev/null)" && [ -n "$pr_num" ]; then
    descriptor="pr-${pr_num}"
  elif [ -n "${ISSUE:-}" ]; then
    descriptor="issue-${ISSUE}"
  elif [ -n "$pr" ]; then
    descriptor="issue-${pr}"
  else
    descriptor="session-$(basename "$transcript" .jsonl | tr -c 'A-Za-z0-9' '-' | cut -c1-12)"
  fi
fi

# Per-family rate table (input, output, cache_write, cache_read) passed to the
# pure core. Rates live ONLY in token-rates.sh — never hard-coded in python.
rates=""
for fam in opus sonnet haiku; do
  rates="${rates}${fam} $(token_rate "$fam" input) $(token_rate "$fam" output) $(token_rate "$fam" cache_write) $(token_rate "$fam" cache_read)
"
done

python3 - "$transcript" "$to_stdout" "$output_dir" "$descriptor" "$fmt" "$rates" "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[7], 'scripts', 'lib'))
import journey_render as J

transcript, to_stdout = sys.argv[1], sys.argv[2] == "1"
output_dir, descriptor, fmt, rates_blob = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
# Neutralise path separators / control chars in a caller-supplied descriptor so
# it cannot escape output_dir (filename component only).
descriptor = J.re.sub(r'[^A-Za-z0-9._-]', '-', descriptor) or 'session'
FAM = J.build_fam(rates_blob)

tree, uuid_root, intakes, total_turns, fam_ctx = J.process(transcript, FAM)
subagent_count, warnings = J.add_children(transcript, tree, uuid_root, FAM, fam_ctx)
# #650 item 1 / D2: intake rows aren't model-tagged, so price carry-burden in $
# at the session-dominant model family's cache_read rate (fall back to opus when
# no family carried context spend).
dom_fam = max(fam_ctx, key=fam_ctx.get) if any(v>0 for v in fam_ctx.values()) else 'opus'
dom_rate = FAM[dom_fam]['cache_read']
lines=[]; J.render(tree, intakes, total_turns, lines, dom_fam, dom_rate, subagent_count, warnings)
# md → human-readable table; json → machine-consumable structure (real JSON, D10).
report=J.render_json(tree, intakes, total_turns, dom_fam, dom_rate, subagent_count, warnings) if fmt=="json" else "\n".join(lines)
# Deterministic, transcript-sourced filename — re-runs are idempotent.
stamp=J.last_ts(transcript)
safe=''.join(ch for ch in stamp if ch.isalnum() or ch=='-')  # 2026-06-07T10:01:00Z -> 2026-06-07T100100Z
os.makedirs(output_dir, exist_ok=True)
path=os.path.join(output_dir, f"{safe}-{descriptor}.{fmt}")
with open(path,'w') as fh: fh.write(report+"\n")

# Output inversion (D8): the report body goes to the FILE; only a ≤3-line
# pointer + headline goes to stdout (the agent's context), unless --stdout.
g_ctx=sum(s['ctx'] for st in tree.values() for s in st.values())
g_op =sum(s['op']  for st in tree.values() for s in st.values())
top_sub=None
for st in tree.values():
    for k,a in st.items():
        if k.startswith('⤷ Agent:') and (top_sub is None or J.tot(a)>top_sub[1]):
            top_sub=(k, J.tot(a))
if to_stdout:
    print(report)
    # Keep a json --stdout stream pure JSON: emit the path on stderr in that mode;
    # for md, append it as the last stdout line (callers parse it there).
    if fmt=="json": sys.stderr.write(path+"\n")
    else: print(path)
else:
    print(f"token-journey report: {path}")
    # #655 item 4: never silently drop subagent info — when none ran, say so
    # explicitly instead of leaving the headline ambiguous.
    sub_seg = (f"  top-subagent={top_sub[0].split(':',1)[1]} ${top_sub[1]:.2f}"
               if top_sub else "  subagents: none detected")
    print(f"  total$={g_ctx+g_op:.3f}  context-tax={g_ctx/(g_op or 1e-9):.1f}x" + sub_seg)
PY
