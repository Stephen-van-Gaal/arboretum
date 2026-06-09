#!/usr/bin/env bash
# owner: pipeline-context-ledger
# read-pipeline-context.sh — emit one field from the pipeline-context cache,
# but only if the cache's head_sha matches the current HEAD. Pure lookup:
# never computes, never writes. Scrubs at the consumer layer before emit.
# See docs/contracts/read-pipeline-context.contract.md.
#
# Usage: bash scripts/read-pipeline-context.sh <issue|spec_index|changed_files|diff_stat>
# Exit: 0 + field on a fresh-SHA hit; non-zero (no stdout) on any miss.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/scrub-control-chars.sh
. "$SCRIPT_DIR/lib/scrub-control-chars.sh"   # exports ARBO_CTRL_CHAR_CLASS

FIELD="${1:?usage: read-pipeline-context.sh <field>}"
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CACHE_FILE="$PROJECT_DIR/.arboretum/pipeline-context-cache.json"
[ -f "$CACHE_FILE" ] || exit 1
HEAD_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")"

ARBO_PC_FIELD="$FIELD" ARBO_PC_HEAD="$HEAD_SHA" \
ARBO_PC_REGISTER="$PROJECT_DIR/docs/REGISTER.md" \
python3 - "$CACHE_FILE" <<'PY' || exit 1
import json, os, re, sys
cls = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])
def scrub(v):
    if isinstance(v, str):  return cls.sub("", v)
    if isinstance(v, list): return [scrub(x) for x in v]
    if isinstance(v, dict): return {k: scrub(x) for k, x in v.items()}
    return v
field = os.environ["ARBO_PC_FIELD"]
if field not in ("issue", "spec_index", "changed_files", "diff_stat"):
    sys.exit(1)
try:
    data = json.load(open(sys.argv[1]))
except (json.JSONDecodeError, OSError):
    sys.exit(1)
if data.get("head_sha") != (os.environ.get("ARBO_PC_HEAD") or None):
    sys.exit(1)
val = data.get(field)
# Empty computed field (e.g. REGISTER unreadable at seed time) is a MISS, not an
# empty hit — so the consumer's live fallback runs (the additive invariant).
if val is None or val == "" or val == [] or val == {}:
    sys.exit(1)
# spec_index is derived from docs/REGISTER.md. The HEAD-SHA gate alone does not
# catch an *uncommitted* REGISTER rewrite at the same HEAD (e.g. /consolidate
# before its commit). If REGISTER's mtime is newer than the cache file's mtime,
# the index is stale — miss so the consumer re-reads it live. Comparing the two
# filesystem mtimes (not the second-floored `written_at` string) keeps the check
# sub-second-precise: the writer reads REGISTER before it writes the cache, so a
# fresh cache always post-dates the REGISTER it captured.
if field == "spec_index":
    reg = os.environ.get("ARBO_PC_REGISTER", "")
    if reg and os.path.exists(reg):
        try:
            if os.path.getmtime(reg) > os.path.getmtime(sys.argv[1]):
                sys.exit(1)
        except OSError:
            pass
val = scrub(val)
if field in ("issue", "changed_files"):
    print(json.dumps(val))
else:
    print(val)
PY
