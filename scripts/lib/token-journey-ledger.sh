#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# token-journey-ledger.sh — append-only per-session push ledger writer.
# Source me; call journey_ledger_capture. Watermark-resumed, uuid-deduped,
# control-char scrubbed. The row schema is pinned by
# docs/contracts/token-journey-ledger.contract.md (TJL-1..5). See slice-1
# design DS1.2/DS1.4 and epic #719 D2.
#
# Dependency-free except python3 (for transcript parsing) + the shared
# journey_render core (skill/stage inference, scrub) and state-dir resolver.

# Device-stable base resolver, sourced once at load — anchors at the main
# checkout, not the invoking worktree (#673).
. "$(dirname "${BASH_SOURCE[0]}")/state-dir.sh"

# Source the shared scrub primitive so ARBO_CTRL_CHAR_CLASS is exported for the
# python heredoc (mirrors token-ledger.sh's robust resolution under zsh/$0).
if [ -n "${BASH_SOURCE:-}" ]; then _arbo_self="${BASH_SOURCE[0]}"; else _arbo_self="$0"; fi
_arbo_scrub="$(dirname "$_arbo_self")/scrub-control-chars.sh"
[ -f "$_arbo_scrub" ] || _arbo_scrub="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/lib/scrub-control-chars.sh"
# shellcheck source=/dev/null
. "$_arbo_scrub"
# Library dir for the python `import journey_render` (resolved at source time).
ARBO_JR_LIBDIR="$(cd "$(dirname "$_arbo_self")" && pwd)"; export ARBO_JR_LIBDIR
unset _arbo_self _arbo_scrub

# journey_ledger_path <session_id> — per-session ledger path; creates the dir.
journey_ledger_path() {
  # Sanitize the session-id filename component (defense in depth — mirrors the
  # descriptor sanitization in the render scripts) so a non-UUID session_id can
  # never compose a path outside the ledger dir.
  local sid="${1:-session}"; sid="${sid//[^A-Za-z0-9._-]/-}"
  local dir; dir="$(arboretum_state_dir)/token-journey-ledger"
  mkdir -p "$dir"
  printf '%s/%s.jsonl' "$dir" "$sid"
}

# journey_ledger_capture <transcript> <ledger> [--stage <stage>]
# Reads assistant messages after the ledger watermark (last uuid) and appends
# one row per new priced message. Stage: --stage override (live, from the
# active-stage-cache) else inferred from STAGE_SKILLS (test/reconciliation,
# DS1.2/DS1.4). Skill always inferred from Skill tool_uses, carried across
# captures via the last row's skill.
journey_ledger_capture() {
  local tx="$1" ledger="$2"; shift 2
  local stage_override=""
  while [ $# -gt 0 ]; do case "$1" in --stage) stage_override="$2"; shift 2;; *) shift;; esac; done
  [ -f "$tx" ] || return 0
  mkdir -p "$(dirname "$ledger")"
  # Crash-safety: if a prior capture was SIGKILLed mid-write leaving a
  # newline-less partial final line, append a separator first so this write
  # cannot concatenate onto (and corrupt) it — which would make both rows
  # unparseable and silently dropped. `tail -c1` in $(...) strips a trailing
  # newline, so a non-empty result means the last byte was NOT a newline.
  [ -s "$ledger" ] && [ -n "$(tail -c1 "$ledger" 2>/dev/null)" ] && printf '\n' >> "$ledger"
  STAGE_OVERRIDE="$stage_override" python3 - "$tx" "$ledger" <<'PY' >> "$ledger"
import json, os, sys
sys.path.insert(0, os.environ.get("ARBO_JR_LIBDIR", os.path.join(os.getcwd(), "scripts", "lib")))
import journey_render as J

tx, ledger = sys.argv[1], sys.argv[2]
stage_override = os.environ.get("STAGE_OVERRIDE", "") or None

# Dedup key is the message id (mid), matching the transcript tree-builder
# (journey_render.process), which dedups on message.id. A single assistant
# message spans many transcript lines sharing one id but distinct uuids, all
# carrying usage (verified ~3x line:mid ratio on a real transcript); deduping on
# uuid here would multiply-count and break the ledger==transcript reconciliation.
# The watermark (last uuid) is only the resume point — correctness rests on mid.
watermark = None; carry_skill = '(direct)'; seen = set()
if os.path.exists(ledger):
    for ln in open(ledger):
        try: o = json.loads(ln)
        except: continue
        if o.get('uuid'): watermark = o['uuid']
        if o.get('mid'): seen.add(o['mid'])
        if o.get('skill'): carry_skill = o['skill']

stage = stage_override or '(pre-workflow)'
skill = carry_skill
passed_watermark = watermark is None
for ln in open(tx):
    try: o = json.loads(ln)
    except: continue
    u = o.get('uuid')
    msg = o.get('message') or {}; usage = msg.get('usage'); mid = msg.get('id')
    content = msg.get('content')
    # Infer skill (and, without an override, stage) from Skill tool_uses — the
    # same derivation J.process uses for the transcript/audit path.
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'tool_use' and c.get('name') == 'Skill':
                sk = J.scrub((c.get('input', {}) or {}).get('skill', '?'))
                short = sk.split(':')[-1]
                if short in J.STAGE_SKILLS:
                    if stage_override is None: stage = short
                    skill = f"{short} (direct)"
                else:
                    skill = sk
    # Advance past the watermark before emitting anything.
    if not passed_watermark:
        if u == watermark: passed_watermark = True
        continue
    if isinstance(usage, dict) and mid and 'input_tokens' in usage and mid not in seen:
        seen.add(mid)
        row = {"uuid": u, "mid": mid, "ts": o.get('timestamp', ''), "model": J.scrub(msg.get('model', '')),
               "stage": J.scrub(stage), "skill": J.scrub(skill),
               "billed": {"input": usage.get('input_tokens', 0), "output": usage.get('output_tokens', 0),
                          "cache_read": usage.get('cache_read_input_tokens', 0),
                          "cache_write": usage.get('cache_creation_input_tokens', 0)}}
        print(json.dumps(row))
PY
}
