#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# parse-plan-checkboxes.sh — Count checkboxes in a plan file.
# Prints "open=N total=N skipped=N" to stdout.
#
# Rules (per docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md D4):
#   - `- [ ] …`                            → open    (counted in total + open)
#   - `- [x] …`                            → resolved (counted in total)
#   - `- [x] (skipped: <reason>) …`        → resolved + skipped (counted in total + skipped)
set -euo pipefail
[ "$#" -eq 1 ] || { echo "Usage: $0 <plan-file>" >&2; exit 1; }
[ -f "$1" ] || { echo "plan file not found: $1" >&2; exit 1; }

python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
re_open    = re.compile(r"^\s*-\s+\[\s\]\s", re.MULTILINE)
re_checked = re.compile(r"^\s*-\s+\[x\]\s",  re.MULTILINE)
re_skipped = re.compile(r"^\s*-\s+\[x\]\s+\(skipped:\s", re.MULTILINE)
open_n    = len(re_open.findall(text))
checked_n = len(re_checked.findall(text))
skipped_n = len(re_skipped.findall(text))
total = open_n + checked_n
print(f"open={open_n} total={total} skipped={skipped_n}")
PY
