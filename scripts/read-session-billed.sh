#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# token-rates.sh is the canonical per-family rate table (single source of truth).
. "$ROOT/scripts/lib/token-rates.sh"
transcript=""; model="opus"
while [ $# -gt 0 ]; do case "$1" in
  --transcript) transcript="$2"; shift 2;; --model) model="$2"; shift 2;; *) shift;; esac; done
[ -n "$transcript" ] || { echo "usage: --transcript <file.jsonl>" >&2; exit 2; }

# Price by the selected model family rather than a hard-coded Opus table, so
# Sonnet/Haiku sessions get a correct est_cost_usd.
r_in="$(token_rate "$model" input)"; r_out="$(token_rate "$model" output)"
r_cw="$(token_rate "$model" cache_write)"; r_cr="$(token_rate "$model" cache_read)"

python3 - "$transcript" "$r_in" "$r_out" "$r_cw" "$r_cr" <<'PY'
import json,sys
path=sys.argv[1]
RW={"input":float(sys.argv[2]),"output":float(sys.argv[3]),
    "cache_write":float(sys.argv[4]),"cache_read":float(sys.argv[5])}
seen=set(); fresh=cw=cr=out=0
spikes=[]
for line in open(path):
    try: o=json.loads(line)
    except Exception: continue
    u=o.get("usage") or (o.get("message") or {}).get("usage")
    mid=(o.get("message") or {}).get("id") or o.get("id")
    if not isinstance(u,dict) or "input_tokens" not in u: continue
    if mid in seen: continue          # DEDUPE by message id (D9)
    seen.add(mid)
    c=u.get("cache_creation_input_tokens",0)
    fresh+=u.get("input_tokens",0); cw+=c
    cr+=u.get("cache_read_input_tokens",0); out+=u.get("output_tokens",0)
    if c>5000: spikes.append((mid,c))  # crude bust detector; tuned via trend in Task 6
tot=fresh+cw+cr
cost=(fresh*RW["input"]+cw*RW["cache_write"]+cr*RW["cache_read"]+out*RW["output"])/1e6
print(f"messages: {len(seen)}")
print(f"fresh_input  {fresh}")
print(f"cache_write  {cw}")
print(f"cache_read   {cr}")
print(f"output       {out}")
print(f"est_cost_usd {cost:.4f}")
share=(cw/tot if tot else 0)
print(f"cache_creation_share {share:.1%}")
print(f"cache_bust_spikes {len(spikes)}" + ("  <-- investigate" if spikes else ""))
PY
