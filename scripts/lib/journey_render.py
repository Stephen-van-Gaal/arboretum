# owner: token-accounting
# journey_render.py — shared renderer core for the token-journey report.
# Imported by read-session-journey.sh (transcript/audit path) and
# render-ledger-journey.sh (push-ledger path). Two tree-builders, one renderer
# (epic #719 D3 / slice-1 DS1.1). Pure function of inputs; zero LLM inference.
#
# Extracted verbatim from read-session-journey.sh's inline heredoc, with one
# behavioural change set: FAM (the rate table) is now an explicit parameter so
# two callers can pass their own, and the CONTEXT INTAKE block is guarded by
# `if intakes:` so the ledger path (intakes=[]) renders no empty stub (DS1.3).
import json, sys, os, re
from collections import OrderedDict

# Defense in depth (CLAUDE.md "scrub author-controlled content into Claude's
# context"): transcript-derived strings (skill names, Bash command text, file
# paths, attributionAgent labels) flow into the report artifact AND stdout.
# Strip ASCII control characters at the source before any of them is rendered.
_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh
def scrub(s): return _CTRL.sub('', str(s))

def build_fam(rates_blob):
    """Parse the `<fam> input output cache_write cache_read` rate block into FAM."""
    FAM = {}
    for ln in rates_blob.splitlines():
        if not ln.strip(): continue
        f, ri, ro, cw, cr = ln.split()
        FAM[f] = dict(input=float(ri), output=float(ro), cache_write=float(cw), cache_read=float(cr))
    return FAM

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
def cost_of(u, model, FAM):
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

def process(path, FAM):
    seen=set(); stage='(pre-workflow)'; skill='(direct)'
    tree=OrderedDict(); uuid_root={}; tooluse={}; intakes=[]; turn_no=0
    fam_ctx={}  # context-$ per model family → session-dominant family (intake pricing, D2)
    with open(path) as f:
        for line in f:
            try: o=json.loads(line)
            except (json.JSONDecodeError, RecursionError): continue
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
                c,p=cost_of(usage,msg.get('model'),FAM)
                fam_ctx[fam(msg.get('model'))]=fam_ctx.get(fam(msg.get('model')),0.0)+c
                a=tree.setdefault(stage,OrderedDict()).setdefault(skill,acc())
                a['ctx']+=c; a['op']+=p; a['turns']+=1
    return tree, uuid_root, intakes, turn_no, fam_ctx

def child_summary(path, FAM):
    seen=set(); ctx=op=0.0; turns=0; puid=None; own=[]; label="subagent"; model=""
    with open(path) as f:
        for line in f:
            try: o=json.loads(line)
            except (json.JSONDecodeError, RecursionError): continue
            if puid is None: puid=o.get('parentUuid')
            if o.get('uuid'): own.append(o['uuid'])
            lbl=o.get('attributionAgent') or o.get('attributionSkill')
            if lbl: label=scrub(lbl)
            msg=o.get('message') or {}; u=msg.get('usage'); mid=msg.get('id')
            if isinstance(u,dict) and mid and mid not in seen and 'input_tokens' in u:
                seen.add(mid); c,p=cost_of(u,msg.get('model'),FAM); ctx+=c; op+=p; turns+=1
                model=msg.get('model',model)
    return dict(ctx=ctx,op=op,turns=turns,parent=puid,own=own,label=label,model=model)

def add_children(session_path, tree, uuid_root, FAM, fam_ctx=None):
    import glob
    sid=os.path.splitext(os.path.basename(session_path))[0]
    subdir=os.path.join(os.path.dirname(session_path), sid, 'subagents')
    agents={p: child_summary(p, FAM) for p in sorted(glob.glob(os.path.join(subdir,'agent-*.jsonl')))}
    warnings=[]  # #655 item 5: collected for an in-file footer, not just stderr
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
            w=(f"unresolved subagent parentUuid in {os.path.basename(p)} "
               f"(parent={s['parent']}); attributing to (pre-workflow)")
            warnings.append(w)
            sys.stderr.write(f"warn: {w}\n")
            root=('(pre-workflow)','(direct)')
        st,_=root
        key=f"⤷ Agent:{s['label']} [{fam(s['model'])}]"
        a=tree.setdefault(st,OrderedDict()).setdefault(key,acc())
        a['ctx']+=s['ctx']; a['op']+=s['op']; a['turns']+=s['turns']
        if fam_ctx is not None:
            fam_ctx[fam(s['model'])]=fam_ctx.get(fam(s['model']),0.0)+s['ctx']
    # #655 item 4: subagent_count distinguishes "none ran" (no agent files) from a
    # fixpoint join miss (files present but unresolved → still produce rows + warn).
    return len(agents), warnings

def _mdcell(s):
    # #651 D5: keep a transcript-derived value a single, inert GFM table cell.
    #  - collapse \r\n\t → space: scrub() keeps newlines, and skill names / ⤷ Agent
    #    labels are author-controlled and NOT line-clamped, so a raw \n would break
    #    the row and inject top-level markdown;
    #  - escape | → \|: | is the column delimiter;
    #  - escape & → &amp; FIRST, then <,> → &lt;/&gt; (canonical html.escape order):
    #    GFM renders raw HTML in cells, and &-first keeps the encoding idempotent.
    # Composes with scrub() (control chars already stripped upstream) and, on the
    # ledger path, with the consumer re-scrub in render-ledger-journey.sh.
    s = re.sub(r'[\r\n\t]+', ' ', str(s))
    s = s.replace('&', '&amp;')
    s = s.replace('|', r'\|')
    return s.replace('<', '&lt;').replace('>', '&gt;')

def render(tree, intakes, total_turns, lines, dom_fam='opus', dom_rate=0.0,
           subagent_count=0, warnings=None, show_intake=True):
    g_ctx=sum(s['ctx'] for st in tree.values() for s in st.values())
    g_op =sum(s['op']  for st in tree.values() for s in st.values())
    # #651 D2: headline as a one-row summary table (right-aligned numerics).
    lines.append("| context$ | operation$ | total$ | tax |")
    lines.append("|--:|--:|--:|--:|")
    lines.append(f"| {g_ctx:.3f} | {g_op:.3f} | {g_ctx+g_op:.3f} | {g_ctx/(g_op or 1e-9):.1f}x |")
    # #651 D3: per-stage section = subtotal header line + skill table. Stages sorted
    # by stage total, skills by skill total. #651 D4: render-time label caps removed.
    for stage in sorted(tree, key=lambda s:-sum(tot(a) for a in tree[s].values())):
        st=tree[stage]
        s_ctx=sum(a['ctx'] for a in st.values()); s_op=sum(a['op'] for a in st.values())
        lines.append(f"\n**{_mdcell(stage)}** — ctx$ {s_ctx:.3f} · op$ {s_op:.3f} · tax {s_ctx/(s_op or 1e-9):.1f}x")
        lines.append("")
        lines.append("| Skill | ctx$ | op$ | n | ctx$/t | tax |")
        lines.append("|---|--:|--:|--:|--:|--:|")
        for sk in sorted(st, key=lambda k:-tot(st[k])):
            a=st[sk]
            # #650 item 2: ctx$/t = context-$ per turn — the late-context signal
            # (a cheap skill made expensive by running late against big context).
            per=a['ctx']/(a['turns'] or 1)
            lines.append(f"| {_mdcell(sk)} | {a['ctx']:.3f} | {a['op']:.3f} | {a['turns']} | {per:.4f} | {taxof(a):.1f}x |")
    # DS1.3: the ledger path passes show_intake=False (it carries no tool_result
    # byte sizes) and must not render an empty-section stub. The transcript/audit
    # path uses the default show_intake=True, so its output is byte-unchanged —
    # including the always-present header when its intakes happen to be empty.
    if show_intake:
        from collections import defaultdict
        by_src=defaultdict(lambda: dict(bytes=0, burden=0.0, n=0))
        for (ti,size,src) in intakes:
            resident=max(0,total_turns-ti)
            b=by_src[src]; b['bytes']+=size; b['burden']+=size*resident; b['n']+=1
        # #650 item 1: ctx$~<fam> ≈ approximate context-rent (burden tokens × dominant
        # family cache_read rate), so the intake half ranks in the same $ unit as the
        # stage/skill half. Approximate (bytes/4 token estimate) — billed remains authoritative.
        # #651 D4: rendered as a table; source label cap removed.
        lines.append("\n### CONTEXT INTAKE (burden = bytes × turns-resident)")
        lines.append("")
        lines.append(f"| source | KB in | reads | burden (MB·turn) | ctx$~{dom_fam} |")
        lines.append("|---|--:|--:|--:|--:|")
        ranked=sorted(by_src.items(), key=lambda kv:-kv[1]['burden'])
        for src,b in ranked[:12]:
            context_usd=b['burden']/4*dom_rate/1e6
            lines.append(f"| {_mdcell(src)} | {b['bytes']/1024:.1f} | {b['n']} | {b['burden']/1e6:.1f} | {context_usd:.4f} |")
        # #655 item 6: no silent [:12] cap — kept as a contiguous italic note line
        # (not tabular), which preserves the "… +N more, $X remainder" contract string.
        rest=ranked[12:]
        if rest:
            rem_usd=sum(b['burden']/4*dom_rate/1e6 for _,b in rest)
            lines.append(f"\n_… +{len(rest)} more, ${rem_usd:.4f} remainder_")
    # #655 item 4: make subagent presence explicit so the reader can tell
    # "none ran" from a fixpoint join miss.
    if subagent_count==0:
        lines.append("\n_subagents: none detected_")
    # #655 item 5: carry stderr warnings into the artifact (D8 output-inversion —
    # the operator reads the file, not stderr) so a (pre-workflow) bucket from an
    # unresolved chain is explained rather than reading as a bug.
    if warnings:
        lines.append("\n**NOTES:**")
        for w in warnings:
            lines.append(f"- warn: {_mdcell(w)}")
        lines.append("- (pre-workflow) above holds cost from subagents whose parent "
                     "turn could not be resolved (see warnings).")

def render_json(tree, intakes, total_turns, dom_fam='opus', dom_rate=0.0,
                subagent_count=0, warnings=None, show_intake=True):
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
    out={
        "totals":{"context":round(g_ctx,6), "operation":round(g_op,6),
                  "total":round(g_ctx+g_op,6), "tax":round(g_ctx/(g_op or 1e-9),3),
                  "intake_priced_at":dom_fam},
        # #655 item 4: explicit subagent presence (detected==0 ⟺ none ran).
        "subagents":{"detected":subagent_count},
        "stages":stages,
    }
    # DS1.3: intake keys only when the caller renders intake (ledger path passes
    # show_intake=False). Transcript path keeps "intake":[] for empty fixtures.
    if show_intake:
        from collections import defaultdict
        by_src=defaultdict(lambda: dict(bytes=0, burden=0.0, n=0))
        for (ti,size,src) in intakes:
            resident=max(0,total_turns-ti)
            b=by_src[src]; b['bytes']+=size; b['burden']+=size*resident; b['n']+=1
        # #650 item 1: context_usd ≈ approximate context-rent at the dominant family rate (D2).
        ranked=sorted(by_src.items(), key=lambda kv:-kv[1]['burden'])
        out["intake"]=[{"source":src, "bytes":b['bytes'], "reads":b['n'], "burden":round(b['burden'],1),
                        "context_usd":round(b['burden']/4*dom_rate/1e6,6)}
                       for src,b in ranked[:12]]
        # #655 item 6: no silent [:12] cap — surface the dropped intake tail.
        rest=ranked[12:]
        if rest:
            out["intake_remainder"]={
                "more":len(rest),
                "bytes":sum(b['bytes'] for _,b in rest),
                "reads":sum(b['n'] for _,b in rest),
                "context_usd":round(sum(b['burden']/4*dom_rate/1e6 for _,b in rest),6),
            }
    # #655 item 5: warnings carried into the artifact (see render() footer).
    if warnings:
        out["notes"]=list(warnings)
    return json.dumps(out, indent=2)

def last_ts(path):
    ts=None
    with open(path) as f:
        for line in f:
            try: o=json.loads(line)
            except (json.JSONDecodeError, RecursionError): continue
            if o.get('timestamp'): ts=o['timestamp']
    return ts or '0000-00-00T000000Z'
