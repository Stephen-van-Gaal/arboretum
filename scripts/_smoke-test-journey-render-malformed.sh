#!/usr/bin/env bash
# owner: token-accounting
# Regression smoke test for scripts/lib/journey_render.py (#776).
# A JSONL line with an oversized integer literal makes json.loads raise a plain
# ValueError (Python 3.11+ integer string-conversion digit limit), which is NOT
# a json.JSONDecodeError. The per-line parse handlers must skip such records,
# not abort the render — preserving the "malformed JSONL lines are skipped"
# invariant. Exercises last_ts (representative of all three identical handlers).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL journey-render-malformed: $1" >&2; exit 1; }

# Module reads ARBO_CTRL_CHAR_CLASS at import (env bridge).
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/scrub-control-chars.sh"

STATE="$(mktemp -d)"; trap 'rm -rf "$STATE"' EXIT
fixture="$STATE/tx.jsonl"
# Line 1: malformed — oversized integer literal → plain ValueError on parse.
# Line 2: well-formed record carrying the timestamp last_ts should return.
python3 - "$fixture" <<'PY'
import sys
big = '{"n": ' + '9'*5000 + '}'
good = '{"timestamp": "2026-06-13T120000Z"}'
open(sys.argv[1], "w").write(big + "\n" + good + "\n")
PY

got="$(ROOT="$ROOT" python3 - "$fixture" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "scripts", "lib"))
import journey_render as J
# Must not raise; must skip the malformed line and return the good timestamp.
print(J.last_ts(sys.argv[1]))
PY
)" || fail "render aborted on malformed (oversized-integer) JSONL line"

[ "$got" = "2026-06-13T120000Z" ] || fail "expected good timestamp, got '$got'"

echo "PASS journey-render-malformed"
