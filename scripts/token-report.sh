#!/usr/bin/env bash
# owner: token-accounting
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sub="${1:-diagnose}"; shift || true
args=("$@")   # preserve sub-args for arms (compare/trend) that re-parse positionally
ledger=""; while [ $# -gt 0 ]; do case "$1" in --ledger) ledger="$2"; shift 2;; *) shift;; esac; done
[ -n "$ledger" ] || ledger="${ARBORETUM_TOKEN_LEDGER:-.arboretum/token-ledger/session.jsonl}"

case "$sub" in
  diagnose)
    # bounded summary only (D5 — never dump the raw ledger)
    jq -s -r '
      group_by(.contributor)[]
      | {c: .[0].contributor, bytes: (map(.bytes)|add), tok: (map(.est_tokens)|add), n: length}
      | "  \(.c)\t\(.n) rows\t\(.bytes) bytes\t~\(.tok) est_tokens"' "$ledger" ;;
  billed)
    t="${ARBORETUM_TRANSCRIPT:-}"; [ -n "$t" ] || { echo "set ARBORETUM_TRANSCRIPT" >&2; exit 2; }
    bash "$ROOT/scripts/read-session-billed.sh" --transcript "$t" ;;
  compare)
    set -- "${args[@]}"
    # set -u would abort with an unbound-variable error on missing paths; emit a
    # controlled usage diagnostic + exit 2 instead (matches the `billed` arm).
    [ $# -ge 2 ] || { echo "usage: token-report.sh compare <base-ledger> <after-ledger>" >&2; exit 2; }
    base="$1"; after="$2"
    python3 - "$base" "$after" <<'PY'
import json,sys
def load(p):
    d={}
    for l in open(p):
        try: r=json.loads(l)
        except: continue
        d[r["contributor"]]=d.get(r["contributor"],0)+r.get("est_tokens",0)
    return d
b,a=load(sys.argv[1]),load(sys.argv[2])
for c in sorted(set(b)|set(a)):
    delta=a.get(c,0)-b.get(c,0)
    sign="+" if delta>0 else ""
    flag="  <-- INFLATED" if delta>0 else ""
    print(f"  {c}\t{sign}{delta} est_tokens{flag}")
PY
    ;;
  trend)
    set -- "${args[@]}"
    while [ $# -gt 0 ]; do case "$1" in --ledger) ledger="$2"; shift 2;; *) shift;; esac; done
    python3 - "$ledger" <<'PY'
import json,sys,statistics as st
from collections import defaultdict
runs=defaultdict(lambda: defaultdict(int))   # (wf,stage,run) -> contributor -> tokens
for l in open(sys.argv[1]):
    try: r=json.loads(l)
    except: continue
    k=(r.get("workflow",""),r.get("stage",""),r.get("run_id",""))
    runs[k][r["contributor"]]+=r.get("est_tokens",0)
# shares per run, grouped by (wf,stage)
buckets=defaultdict(list)
for (wf,stage,run),contrib in runs.items():
    tot=sum(contrib.values()) or 1
    buckets[(wf,stage)].append({c: contrib.get(c,0)/tot for c in contrib})
for (wf,stage),series in buckets.items():
    if len(series)<5: continue
    contribs={c for s in series for c in s}
    for c in sorted(contribs):
        vals=[s.get(c,0) for s in series]
        hist,latest=vals[:-1],vals[-1]
        med=st.median(hist)
        mad=st.median([abs(v-med) for v in hist]) or 1e-9
        if abs(latest-med) > 3*mad:
            d="up" if latest>med else "down"
            print(f"  [{wf} {stage}] {c}-share {d}: {latest:.0%} vs {med:.0%} median (>3*MAD breach)")
PY
    ;;
  busts)
    set -- "${args[@]}"
    t="${ARBORETUM_TRANSCRIPT:-}"
    while [ $# -gt 0 ]; do case "$1" in --transcript) t="$2"; shift 2;; *) shift;; esac; done
    [ -n "$t" ] || { echo "set --transcript or ARBORETUM_TRANSCRIPT" >&2; exit 2; }
    # Per-family cache rates from the canonical table (token-rates.sh); busts
    # prices each bust by the model that re-wrote the cache, not a fixed Opus rate.
    . "$ROOT/scripts/lib/token-rates.sh"
    rates=""
    for fam in opus sonnet haiku; do
      rates="${rates}${fam} $(token_rate "$fam" cache_write) $(token_rate "$fam" cache_read)
"
    done
    python3 - "$t" "$rates" <<'PY'
import json,sys
from datetime import datetime
def ts(s): return datetime.fromisoformat(s.replace("Z","+00:00"))
# Canonical per-family cache (write, read) rates passed from bash (token-rates.sh).
FAM={}
for _ln in sys.argv[2].splitlines():
    if not _ln.strip(): continue
    _f,_cw,_cr=_ln.split(); FAM[_f]=(float(_cw),float(_cr))
def _rates(m):
    m=(m or "").lower()
    for fam in ("opus","sonnet","haiku"):
        if fam in m: return FAM.get(fam, FAM.get("opus",(6.25,0.50)))
    return FAM.get("opus",(6.25,0.50))
rows=[]; seen=set(); compaction_after=set()
prev_real=None
for line in open(sys.argv[1]):
    try: o=json.loads(line)
    except: continue
    if o.get("isCompactSummary") is True:
        compaction_after.add(len(rows)); continue       # next real turn follows a compaction
    m=o.get("message") or {}; u=m.get("usage"); mid=m.get("id")
    if not isinstance(u,dict) or "input_tokens" not in u or not mid or mid in seen: continue
    seen.add(mid)
    rows.append({"id":mid,"t":o.get("timestamp"),"model":m.get("model",""),
                 "read":u.get("cache_read_input_tokens",0),"cw":u.get("cache_creation_input_tokens",0),
                 "after_compaction": len(rows) in compaction_after})
waste=0.0
print(f"{'turn':>4} {'deficit':>9} {'$waste':>7}  cause")
for i in range(1,len(rows)):
    p,c=rows[i-1],rows[i]
    expected=p["read"]+p["cw"]; deficit=expected-c["read"]
    if not (expected>10000 and deficit>0.25*expected and deficit>5000): continue
    if c["after_compaction"]:
        cause="compaction (expected — excluded from waste)"; w=0.0
    elif c["model"]!=p["model"]:
        r_cw,r_cr=_rates(c["model"])
        cause=f"model switch ({p['model']}→{c['model']})"; w=deficit*(r_cw-r_cr)/1e6
    else:
        gap=(ts(c["t"])-ts(p["t"])).total_seconds()
        r_cw,r_cr=_rates(c["model"])
        if gap>300: cause=f"TTL expiry (idle {gap/60:.0f}m)"; w=deficit*(r_cw-r_cr)/1e6
        else: cause="prefix change (CLAUDE.md/tools/system) — needs hook"; w=deficit*(r_cw-r_cr)/1e6
    waste+=w
    print(f"{i:>4} {deficit:>9,} {w:>7.4f}  {cause}")
print(f"\ntotal avoidable cache-bust cost: ${waste:.4f}  (compaction excluded)")
PY
    ;;
  *) echo "unknown subcommand: $sub" >&2; exit 2 ;;
esac
