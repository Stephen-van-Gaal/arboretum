#!/usr/bin/env bash
# owner: token-accounting
# render-ledger-journey.sh — render the token-journey report from a push ledger.
# The ledger tree-builder + the shared renderer (epic #719 D3 / slice-1 DS1.5).
# The transcript audit path stays in read-session-journey.sh --transcript.
# Contract: docs/contracts/render-ledger-journey.cli-contract.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/token-rates.sh"
. "$ROOT/scripts/lib/state-dir.sh"
. "$ROOT/scripts/lib/scrub-control-chars.sh"

ledger=""; to_stdout=0; output_dir=""; descriptor=""; fmt="md"
while [ $# -gt 0 ]; do case "$1" in
  --ledger) ledger="$2"; shift 2;;
  --stdout) to_stdout=1; shift;;
  --output-dir) output_dir="$2"; shift 2;;
  --descriptor) descriptor="$2"; shift 2;;
  --format) fmt="$2"; shift 2;;
  *) shift;; esac; done
[ -n "$ledger" ] || { echo "usage: render-ledger-journey.sh --ledger <file.jsonl> [--stdout] [--output-dir D] [--descriptor X] [--format md|json]" >&2; exit 2; }
[ -f "$ledger" ] || { echo "render-ledger-journey.sh: ledger not found: $ledger" >&2; exit 2; }
# Default base anchors at the main checkout, not the invoking worktree (#673).
[ -n "$output_dir" ] || output_dir="$(arboretum_state_dir)/token-journey"
[ -n "$descriptor" ] || descriptor="session-$(basename "$ledger" .jsonl | tr -c 'A-Za-z0-9' '-' | cut -c1-12)"

# Per-family rate table — rates live ONLY in token-rates.sh, never in python.
rates=""
for fam in opus sonnet haiku; do
  rates="${rates}${fam} $(token_rate "$fam" input) $(token_rate "$fam" output) $(token_rate "$fam" cache_write) $(token_rate "$fam" cache_read)
"
done

PYTHONUTF8=1 python3 - "$ledger" "$to_stdout" "$output_dir" "$descriptor" "$fmt" "$rates" "$ROOT" <<'PY'
import sys, os, json
sys.path.insert(0, os.path.join(sys.argv[7], 'scripts', 'lib'))
import journey_render as J

ledger, to_stdout = sys.argv[1], sys.argv[2] == "1"
output_dir, descriptor, fmt, rates_blob = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
descriptor = J.re.sub(r'[^A-Za-z0-9._-]', '-', descriptor) or 'session'
FAM = J.build_fam(rates_blob)

# Ledger tree-builder: rows -> the renderer's stage->skill->{ctx,op,turns} tree.
# Raw billed token counts are priced here via cost_of (same path as the
# transcript builder), so the rate table stays single-sourced in token-rates.sh.
tree = J.OrderedDict(); fam_ctx = {}; last_ts = '0000-00-00T000000Z'
for ln in open(ledger):
    try: o = json.loads(ln)
    except: continue
    if o.get('ts'): last_ts = o['ts']
    b = o.get('billed') or {}
    usage = {"input_tokens": b.get('input', 0), "output_tokens": b.get('output', 0),
             "cache_read_input_tokens": b.get('cache_read', 0),
             "cache_creation_input_tokens": b.get('cache_write', 0)}
    model = o.get('model', '')
    c, p = J.cost_of(usage, model, FAM)
    fam_ctx[J.fam(model)] = fam_ctx.get(J.fam(model), 0.0) + c
    # Defense in depth (CLAUDE.md § "scrub again at the consumer"): re-scrub the
    # transcript-derived stage/skill read from the durable ledger before they
    # become rendered tree keys / report body / stdout — belt-and-braces against
    # a hand-edited or older-writer-version ledger row.
    st = J.scrub(o.get('stage', '(pre-workflow)')); sk = J.scrub(o.get('skill', '(direct)'))
    a = tree.setdefault(st, J.OrderedDict()).setdefault(sk, J.acc())
    a['ctx'] += c; a['op'] += p; a['turns'] += 1

dom_fam = max(fam_ctx, key=fam_ctx.get) if any(v > 0 for v in fam_ctx.values()) else 'opus'
dom_rate = FAM[dom_fam]['cache_read']
# DS1.3: the ledger carries no tool_result byte sizes — intakes=[] and
# show_intake=False so the CONTEXT INTAKE section is omitted entirely.
if fmt == "json":
    report = J.render_json(tree, [], 0, dom_fam, dom_rate, 0, None, show_intake=False)
else:
    lines = []; J.render(tree, [], 0, lines, dom_fam, dom_rate, 0, None, show_intake=False)
    report = "\n".join(lines)

# Deterministic, ledger-sourced filename — re-runs are idempotent.
safe = ''.join(ch for ch in last_ts if ch.isalnum() or ch == '-')
os.makedirs(output_dir, exist_ok=True)
path = os.path.join(output_dir, f"{safe}-{descriptor}.{fmt}")
with open(path, 'w') as fh: fh.write(report + "\n")

# Output inversion (D8): body to the file; ≤3-line pointer + headline to stdout.
g_ctx = sum(s['ctx'] for st in tree.values() for s in st.values())
g_op  = sum(s['op']  for st in tree.values() for s in st.values())
if to_stdout:
    print(report)
    if fmt == "json": sys.stderr.write(path + "\n")
    else: print(path)
else:
    print(f"token-journey report: {path}")
    print(f"  total$={g_ctx+g_op:.3f}  context-tax={g_ctx/(g_op or 1e-9):.1f}x  (push-ledger)")
PY
