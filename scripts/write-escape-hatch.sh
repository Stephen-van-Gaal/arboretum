#!/usr/bin/env bash
# owner: workflow-management
# write-escape-hatch.sh — Append an `escape-hatch:` block to the
# frontmatter of a design spec. Idempotent: a second call replaces
# the existing block in place (rather than appending a duplicate).
#
# Per docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md D4 (escape-hatch exit).
#
# Usage:
#   bash scripts/write-escape-hatch.sh <design-spec> <trigger-name> <redirect-target>
set -euo pipefail
[ "$#" -eq 3 ] || { echo "Usage: $0 <design-spec> <trigger-name> <redirect-target>" >&2; exit 1; }
SPEC="$1"; TRIGGER="$2"; REDIRECT="$3"
[ -f "$SPEC" ] || { echo "design spec not found: $SPEC" >&2; exit 1; }

export TRIGGER REDIRECT
python3 - "$SPEC" <<'PY'
import os, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
trigger  = os.environ["TRIGGER"]
redirect = os.environ["REDIRECT"]

m = re.match(r"^(---\n)(.*?\n)(---\n)", text, re.DOTALL)
if not m:
    sys.stderr.write("write-escape-hatch: no frontmatter found\n")
    sys.exit(2)
opening, body, closing = m.group(1), m.group(2), m.group(3)
rest = text[m.end():]

# Strip any existing escape-hatch block (idempotent — second call
# replaces). Match the `escape-hatch:` line + any indented sub-lines.
body = re.sub(
    r"(?:^|\n)escape-hatch:\n(?:  [^\n]*\n)+",
    "\n",
    body,
)

if not body.endswith("\n"):
    body += "\n"
body += f"escape-hatch:\n  trigger: {trigger}\n  redirect-target: {redirect}\n"

open(path, "w", encoding="utf-8").write(opening + body + closing + rest)
PY
