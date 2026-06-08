#!/usr/bin/env bash
# owner: token-accounting
# read-session-journey.sh — per-stage/skill/subagent token cost from a transcript.
# Bash senses the environment (rates, config, descriptor); python is a pure
# function of its inputs. Zero LLM inference. See token-journey design spec D1–D10.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/token-rates.sh"

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
[ -n "$output_dir" ] || output_dir=".arboretum/token-journey"

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

python3 - "$transcript" "$to_stdout" "$output_dir" "$descriptor" "$fmt" "$rates" <<'PY'
import json, sys, os, re
from collections import OrderedDict

# Defense in depth (CLAUDE.md "scrub author-controlled content into Claude's
# context"): transcript-derived strings (skill names, Bash command text, file
# paths, attributionAgent labels) flow into the report artifact AND stdout.
# Strip ASCII control characters at the source before any of them is rendered.
_CTRL = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]')
def scrub(s): return _CTRL.sub('', str(s))

transcript, to_stdout = sys.argv[1], sys.argv[2] == "1"
output_dir, descriptor, fmt, rates_blob = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
# Neutralise path separators / control chars in a caller-supplied descriptor so
# it cannot escape output_dir (filename component only).
descriptor = re.sub(r'[^A-Za-z0-9._-]', '-', descriptor) or 'session'
FAM = {}
for ln in rates_blob.splitlines():
    if not ln.strip(): continue
    f, ri, ro, cw, cr = ln.split()
    FAM[f] = dict(input=float(ri), output=float(ro), cache_write=float(cw), cache_read=float(cr))
STAGE_SKILLS = {
    'start','start-bugfix','design','build','finish','cleanup','land','pr','architect',
    'init','init-project','consolidate','publish','security-review','reflect','roadmap',
    'handoff','health-check',
}
def fam(model):
    m = (model or '').lower()
    for f in ('opus','sonnet','haiku'):
        if f in m: return f
    return 'opus'
def cost_of(u, model):
    r = FAM[fam(model)]
    cr = u.get('cache_read_input_tokens',0); cw = u.get('cache_creation_input_tokens',0)
    fr = u.get('input_tokens',0); ot = u.get('output_tokens',0)
    return cr*r['cache_read']/1e6, (fr*r['input'] + cw*r['cache_write'] + ot*r['output'])/1e6
def acc(): return dict(ctx=0.0, op=0.0, turns=0)
def tot(a): return a['ctx'] + a['op']
def taxof(a): return a['ctx'] / (a['op'] or 1e-9)
def _strip_cd(cmd):
    # #650 item 3: drop a leading `cd <path> &&` / `cd <path> ;` navigation
    # preamble so the operative command — not the shared cd prefix every
    # governance call carries — becomes the intake grouping key. Minimal,
    # predictable strip (design D3); not a full command parser.
    return re.sub(r'^\s*cd\s+[^&;]*?(?:&&|;)\s*', '', cmd, count=1)
def source_label(tu):
    name=scrub(tu.get('name','?')); inp=tu.get('input',{}) or {}
    if name=='Read':  return scrub(f"Read {os.path.basename(inp.get('file_path',''))}")
    if name=='Bash':
        cmd=(inp.get('command','') or '').strip()
        if not cmd: return "Bash"
        op=_strip_cd(cmd).strip() or cmd
        return scrub(f"Bash {op.splitlines()[0][:30]}")
    if name=='Skill': return scrub(f"Skill {inp.get('skill','?')}")
    if name=='Agent': return scrub(f"Agent {inp.get('subagent_type','?')}")
    if name in ('Glob','Grep'): return scrub(f"{name} {inp.get('pattern','')[:24]}")
    if name in ('Edit','Write'): return scrub(f"{name} {os.path.basename(inp.get('file_path',''))}")
    return name

def process(path):
    seen=set(); stage='(pre-workflow)'; skill='(direct)'
    tree=OrderedDict(); uuid_root={}; tooluse={}; intakes=[]; turn_no=0
    fam_ctx={}  # context-$ per model family → session-dominant family (intake pricing, D2)
    for line in open(path):
        try: o=json.loads(line)
        except: continue
        u=o.get('uuid')
        msg=o.get('message') or {}; usage=msg.get('usage'); mid=msg.get('id')
        content=msg.get('content'); skill_invoked=None
        if isinstance(content,list):
            for c in content:
                if not isinstance(c,dict): continue
                if c.get('type')=='tool_use':
                    tooluse[c.get('id')]=source_label(c)
                    if c.get('name')=='Skill':
                        skill_invoked=scrub((c.get('input',{}) or {}).get('skill','?'))
                if c.get('type')=='tool_result':
                    intakes.append((turn_no, len(str(c.get('content',''))),
                                    tooluse.get(c.get('tool_use_id'),'context/system')))
        if skill_invoked:
            short=skill_invoked.split(':')[-1]
            if short in STAGE_SKILLS: stage=short; skill=f"{short} (direct)"
            else: skill=skill_invoked
        if u is not None: uuid_root[u]=(stage,skill)
        if isinstance(usage,dict) and mid and mid not in seen and 'input_tokens' in usage:
            seen.add(mid); turn_no+=1
            c,p=cost_of(usage,msg.get('model'))
            fam_ctx[fam(msg.get('model'))]=fam_ctx.get(fam(msg.get('model')),0.0)+c
            a=tree.setdefault(stage,OrderedDict()).setdefault(skill,acc())
            a['ctx']+=c; a['op']+=p; a['turns']+=1
    return tree, uuid_root, intakes, turn_no, fam_ctx

def child_summary(path):
    seen=set(); ctx=op=0.0; turns=0; puid=None; own=[]; label="subagent"; model=""
    for line in open(path):
        try: o=json.loads(line)
        except: continue
        if puid is None: puid=o.get('parentUuid')
        if o.get('uuid'): own.append(o['uuid'])
        lbl=o.get('attributionAgent') or o.get('attributionSkill')
        if lbl: label=scrub(lbl)
        msg=o.get('message') or {}; u=msg.get('usage'); mid=msg.get('id')
        if isinstance(u,dict) and mid and mid not in seen and 'input_tokens' in u:
            seen.add(mid); c,p=cost_of(u,msg.get('model')); ctx+=c; op+=p; turns+=1
            model=msg.get('model',model)
    return dict(ctx=ctx,op=op,turns=turns,parent=puid,own=own,label=label,model=model)

def add_children(session_path, tree, uuid_root, fam_ctx=None):
    import glob
    sid=os.path.splitext(os.path.basename(session_path))[0]
    subdir=os.path.join(os.path.dirname(session_path), sid, 'subagents')
    agents={p: child_summary(p) for p in sorted(glob.glob(os.path.join(subdir,'agent-*.jsonl')))}
    resolved={}
    # Fixpoint: resolve any agent whose parent is known, seeding its own uuids,
    # until no further progress. Depth-agnostic — grandchildren resolve once
    # their parent (a child) is itself resolved.
    progress=True
    while progress:
        progress=False
        for p,s in agents.items():
            if p in resolved: continue
            root=uuid_root.get(s['parent'])
            if root is not None:
                resolved[p]=root
                for uu in s['own']: uuid_root[uu]=root
                progress=True
    for p,s in agents.items():
        root=resolved.get(p)
        if root is None:
            sys.stderr.write(f"warn: unresolved subagent parentUuid in {os.path.basename(p)} "
                             f"(parent={s['parent']}); attributing to (pre-workflow)\n")
            root=('(pre-workflow)','(direct)')
        st,_=root
        key=f"⤷ Agent:{s['label']} [{fam(s['model'])}]"
        a=tree.setdefault(st,OrderedDict()).setdefault(key,acc())
        a['ctx']+=s['ctx']; a['op']+=s['op']; a['turns']+=s['turns']
        if fam_ctx is not None:
            fam_ctx[fam(s['model'])]=fam_ctx.get(fam(s['model']),0.0)+s['ctx']

def render(tree, intakes, total_turns, lines, dom_fam='opus', dom_rate=0.0):
    g_ctx=sum(s['ctx'] for st in tree.values() for s in st.values())
    g_op =sum(s['op']  for st in tree.values() for s in st.values())
    lines.append(f"context$={g_ctx:.3f} operation$={g_op:.3f} total$={g_ctx+g_op:.3f} "
                 f"tax={g_ctx/(g_op or 1e-9):.1f}x")
    for stage in sorted(tree, key=lambda s:-sum(tot(a) for a in tree[s].values())):
        st=tree[stage]
        s_ctx=sum(a['ctx'] for a in st.values()); s_op=sum(a['op'] for a in st.values())
        lines.append(f"  STAGE {stage:<22} ctx${s_ctx:>8.3f} op${s_op:>8.3f} tax={s_ctx/(s_op or 1e-9):.1f}x")
        for sk in sorted(st, key=lambda k:-tot(st[k])):
            a=st[sk]
            # #650 item 2: ctx$/t = context-$ per turn — the late-context signal
            # (a cheap skill made expensive by running late against big context).
            per=a['ctx']/(a['turns'] or 1)
            lines.append(f"      {sk[:34]:<34} ctx${a['ctx']:>8.3f} op${a['op']:>8.3f} n={a['turns']:<4} ctx$/t {per:>7.4f} tax={taxof(a):.1f}x")
    from collections import defaultdict
    by_src=defaultdict(lambda: dict(bytes=0, burden=0.0, n=0))
    for (ti,size,src) in intakes:
        resident=max(0,total_turns-ti)
        b=by_src[src]; b['bytes']+=size; b['burden']+=size*resident; b['n']+=1
    # #650 item 1: ctx$~<fam> ≈ approximate context-rent (burden tokens × dominant
    # family cache_read rate), so the intake half ranks in the same $ unit as the
    # stage/skill half. Approximate (bytes/4 token estimate) — billed remains authoritative.
    lines.append("\n  CONTEXT INTAKE (burden = bytes × turns-resident):")
    lines.append(f"  {'source':<40}{'KB in':>8}{'reads':>7}{'burden(MB·turn)':>16}{'ctx$~'+dom_fam:>12}")
    for src,b in sorted(by_src.items(), key=lambda kv:-kv[1]['burden'])[:12]:
        context_usd=b['burden']/4*dom_rate/1e6
        lines.append(f"  {src[:40]:<40}{b['bytes']/1024:>8.1f}{b['n']:>7}{b['burden']/1e6:>16.1f}{context_usd:>12.4f}")

def render_json(tree, intakes, total_turns, dom_fam='opus', dom_rate=0.0):
    g_ctx=sum(s['ctx'] for st in tree.values() for s in st.values())
    g_op =sum(s['op']  for st in tree.values() for s in st.values())
    stages=[]
    for stage in sorted(tree, key=lambda s:-sum(tot(a) for a in tree[s].values())):
        st=tree[stage]
        s_ctx=sum(a['ctx'] for a in st.values()); s_op=sum(a['op'] for a in st.values())
        skills=[{"label":sk, "context":round(st[sk]['ctx'],6), "operation":round(st[sk]['op'],6),
                 "turns":st[sk]['turns'],
                 "context_per_turn":round(st[sk]['ctx']/(st[sk]['turns'] or 1),6),  # #650 item 2
                 "tax":round(taxof(st[sk]),3)}
                for sk in sorted(st, key=lambda k:-tot(st[k]))]
        stages.append({"stage":stage, "context":round(s_ctx,6), "operation":round(s_op,6),
                       "tax":round(s_ctx/(s_op or 1e-9),3), "skills":skills})
    from collections import defaultdict
    by_src=defaultdict(lambda: dict(bytes=0, burden=0.0, n=0))
    for (ti,size,src) in intakes:
        resident=max(0,total_turns-ti)
        b=by_src[src]; b['bytes']+=size; b['burden']+=size*resident; b['n']+=1
    # #650 item 1: context_usd ≈ approximate context-rent at the dominant family rate (D2).
    intake=[{"source":src, "bytes":b['bytes'], "reads":b['n'], "burden":round(b['burden'],1),
             "context_usd":round(b['burden']/4*dom_rate/1e6,6)}
            for src,b in sorted(by_src.items(), key=lambda kv:-kv[1]['burden'])[:12]]
    return json.dumps({
        "totals":{"context":round(g_ctx,6), "operation":round(g_op,6),
                  "total":round(g_ctx+g_op,6), "tax":round(g_ctx/(g_op or 1e-9),3),
                  "intake_priced_at":dom_fam},
        "stages":stages, "intake":intake,
    }, indent=2)

def last_ts(path):
    ts=None
    for line in open(path):
        try: o=json.loads(line)
        except: continue
        if o.get('timestamp'): ts=o['timestamp']
    return ts or '0000-00-00T000000Z'

tree, uuid_root, intakes, total_turns, fam_ctx = process(transcript)
add_children(transcript, tree, uuid_root, fam_ctx)
# #650 item 1 / D2: intake rows aren't model-tagged, so price carry-burden in $
# at the session-dominant model family's cache_read rate (fall back to opus when
# no family carried context spend).
dom_fam = max(fam_ctx, key=fam_ctx.get) if any(v>0 for v in fam_ctx.values()) else 'opus'
dom_rate = FAM[dom_fam]['cache_read']
lines=[]; render(tree, intakes, total_turns, lines, dom_fam, dom_rate)
# md → human-readable table; json → machine-consumable structure (real JSON, D10).
report=render_json(tree, intakes, total_turns, dom_fam, dom_rate) if fmt=="json" else "\n".join(lines)
# Deterministic, transcript-sourced filename — re-runs are idempotent.
stamp=last_ts(transcript)
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
        if k.startswith('⤷ Agent:') and (top_sub is None or tot(a)>top_sub[1]):
            top_sub=(k, tot(a))
if to_stdout:
    print(report)
    # Keep a json --stdout stream pure JSON: emit the path on stderr in that mode;
    # for md, append it as the last stdout line (callers parse it there).
    if fmt=="json": sys.stderr.write(path+"\n")
    else: print(path)
else:
    print(f"token-journey report: {path}")
    print(f"  total$={g_ctx+g_op:.3f}  context-tax={g_ctx/(g_op or 1e-9):.1f}x"
          + (f"  top-subagent={top_sub[0].split(':',1)[1]} ${top_sub[1]:.2f}" if top_sub else ""))
PY
