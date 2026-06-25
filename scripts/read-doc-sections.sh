#!/usr/bin/env bash
# owner: document-access
# scope: plugin-only
set -euo pipefail

[ "$#" -ge 2 ] || { echo "Usage: $0 <markdown-file> <section-key>..." >&2; exit 2; }
[ -f "$1" ] || { echo "read-doc-sections: file not found: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPLORER="$SCRIPT_DIR/explore-doc.sh"
SECTION_READER="$SCRIPT_DIR/read-doc-section.sh"
[ -f "$EXPLORER" ] || { echo "read-doc-sections: explorer not found at $EXPLORER" >&2; exit 1; }
[ -f "$SECTION_READER" ] || { echo "read-doc-sections: section reader not found at $SECTION_READER" >&2; exit 1; }

DOC="$1"
shift
EXPLORE_OUT="$(mktemp)"
HEADINGS="$(mktemp)"
SECTIONS_DIR="$(mktemp -d)"
trap 'rm -f "$EXPLORE_OUT" "$HEADINGS"; rm -rf "$SECTIONS_DIR"' EXIT

if ! bash "$EXPLORER" "$DOC" >"$EXPLORE_OUT"; then
  exit 1
fi

python3 - "$EXPLORE_OUT" "$@" >"$HEADINGS" <<'PY'
import re
import sys

explore_path = sys.argv[1]
requested = sys.argv[2:]


def fail(message, code=1):
    sys.stderr.write(f"read-doc-sections: {message}\n")
    sys.exit(code)


sections = {}
current = None
index_re = re.compile(r"^section\[(\d+)\]\.(key|alias|heading|level|source)=(.*)$")
with open(explore_path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        match = index_re.match(line)
        if not match:
            continue
        index = int(match.group(1))
        field = match.group(2)
        value = match.group(3)
        current = sections.setdefault(index, {})
        if field == "alias":
            current.setdefault("aliases", []).append(value)
        else:
            current[field] = value

by_key = {}
for section in sections.values():
    key = section.get("key")
    heading = section.get("heading")
    if key and heading:
        by_key.setdefault(key, []).append(heading)
    if heading:
        for alias in section.get("aliases", []):
            by_key.setdefault(alias, []).append(heading)

resolved = []
for key in requested:
    matches = by_key.get(key, [])
    if not matches:
        fail(f"section key not found: {key}")
    if len(matches) > 1:
        fail(f"section key is ambiguous: {key}")
    resolved.append(matches[0])

for heading in resolved:
    print(heading)
PY

count=0
failed=0
section_files=()
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  count=$((count + 1))
  out_file="$SECTIONS_DIR/$count.md"
  err_file="$SECTIONS_DIR/$count.err"
  if bash "$SECTION_READER" "$DOC" "$heading" >"$out_file" 2>"$err_file"; then
    section_files+=("$out_file")
  else
    sed 's/^read-doc-section:/read-doc-sections:/' "$err_file" >&2
    failed=1
  fi
done <"$HEADINGS"

if [ "$failed" != 0 ]; then
  exit 1
fi

first=true
for section_file in "${section_files[@]}"; do
  if [ "$first" = true ]; then
    first=false
  else
    printf '\n'
  fi
  cat "$section_file"
done
