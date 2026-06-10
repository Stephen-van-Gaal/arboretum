#!/usr/bin/env bash
# owner: document-access
set -euo pipefail

# read-decisions.sh — two-altitude projection over a governed-spec Decisions table.
# Composes over read-doc-section.sh; consumes docs/contracts/document-access-format.contract.md.
# Usage: read-decisions.sh <markdown-file> [--summary | --detail <ID[,ID...]>]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

file=""; mode="summary"; ids=""; mode_set=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary)
      [ -n "$mode_set" ] && { echo "read-decisions: --summary and --detail are mutually exclusive (or repeated)" >&2; exit 2; }
      mode="summary"; mode_set=1; shift ;;
    --detail)
      [ -n "$mode_set" ] && { echo "read-decisions: --summary and --detail are mutually exclusive (or repeated)" >&2; exit 2; }
      mode="detail"; mode_set=1; ids="${2:-}"
      [ -z "$ids" ] && { echo "read-decisions: --detail requires a comma-separated ID list" >&2; exit 2; }
      shift 2 ;;
    --*) echo "read-decisions: unknown flag: $1" >&2; exit 2 ;;
    *)
      [ -n "$file" ] && { echo "read-decisions: unexpected argument: $1" >&2; exit 2; }
      file="$1"; shift ;;
  esac
done
[ -n "$file" ] || { echo "read-decisions: missing <markdown-file>" >&2; exit 2; }
[ -f "$file" ] || { echo "read-decisions: file not found: $file" >&2; exit 1; }

# Extract the Decisions section via the generic reader (fail-closed if absent).
section="$(bash "$ROOT/scripts/read-doc-section.sh" "$file" "Decisions" 2>/dev/null)" || {
  echo "read-decisions: no 'Decisions' section in $file" >&2; exit 1; }

# Stage the section to a temp file: the heredoc below feeds python its *program*
# on stdin (the `-`), so the script reads the section via a path argument, not
# stdin (which would otherwise be consumed by the interpreter reading the program).
section_file="$(mktemp)"
trap 'rm -f "$section_file"' EXIT
printf '%s\n' "$section" > "$section_file"

python3 - "$mode" "$ids" "$section_file" <<'PY'
import sys, re

mode, ids_arg, section_path = sys.argv[1], sys.argv[2], sys.argv[3]
ids = [i.strip() for i in ids_arg.split(",") if i.strip()] if ids_arg else []

with open(section_path, encoding="utf-8") as _h:
    _section_text = _h.read()

rows = []  # list of (cells:list[str], raw:str)
header = None
for line in _section_text.splitlines():
    s = line.strip()
    if not s.startswith("|"):
        continue
    # Split on unescaped pipes only — a cell may contain an escaped \| (valid
    # Markdown), which must not be treated as a column boundary.
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", s.strip("|"))]
    if set("".join(cells)) <= set("-: "):   # separator row
        continue
    if header is None:
        header = [re.sub(r"\s+", " ", c).strip().casefold() for c in cells]
        continue
    rows.append((cells, line))


def fail(msg):
    sys.stderr.write("read-decisions: %s\n" % msg)
    sys.exit(1)


if header is None or not rows:
    fail("no decision rows found")


def col(name):
    try:
        return header.index(name)
    except ValueError:
        return None


i_id, i_dec = col("id"), col("decision")
i_status, i_tags = col("status"), col("tags")
if i_id is None or i_dec is None:
    fail("Decisions table missing ID/Decision columns")


def cell(cells, idx):
    return cells[idx] if (idx is not None and idx < len(cells)) else ""


if mode == "summary":
    out = []
    for cells, _ in rows:
        status = cell(cells, i_status) or "active"
        tags = cell(cells, i_tags)
        out.append("%s · %s · %s · %s" % (cell(cells, i_id), cell(cells, i_dec), status, tags))
    sys.stdout.write("\n".join(out) + "\n")
else:  # detail
    by_id = {}
    for cells, raw in rows:
        key = cell(cells, i_id)
        if key in by_id:
            fail("duplicate decision id in table: %s" % key)
        by_id[key] = raw
    picked = []
    for want in ids:
        if want not in by_id:
            fail("decision id not found: %s" % want)
        picked.append(by_id[want])
    sys.stdout.write("\n".join(picked) + "\n")
PY
