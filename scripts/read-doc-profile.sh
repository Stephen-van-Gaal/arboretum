#!/usr/bin/env bash
# owner: document-access
# scope: plugin-only
set -euo pipefail

[ "$#" -eq 2 ] || { echo "Usage: $0 <markdown-file> <profile-name>" >&2; exit 2; }
[ -f "$1" ] || { echo "read-doc-profile: file not found: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
SECTION_READER="$SCRIPT_DIR/read-doc-section.sh"
[ -f "$YAML_LITE" ] || { echo "read-doc-profile: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }
[ -f "$SECTION_READER" ] || { echo "read-doc-profile: section reader not found at $SECTION_READER" >&2; exit 1; }

PARSED="$(mktemp)"
PARSER_ERR="$(mktemp)"
SECTIONS="$(mktemp)"
SECTIONS_DIR="$(mktemp -d)"
trap 'rm -f "$PARSED" "$PARSER_ERR" "$SECTIONS"; rm -rf "$SECTIONS_DIR"' EXIT

if ! bash "$YAML_LITE" frontmatter "$1" >"$PARSED" 2>"$PARSER_ERR"; then
  echo "read-doc-profile: invalid or missing frontmatter" >&2
  sed 's/^/read-doc-profile: /' "$PARSER_ERR" >&2
  exit 1
fi

python3 - "$PARSED" "$2" >"$SECTIONS" <<'PY'
import sys

parsed_path = sys.argv[1]
profile = sys.argv[2]


def fail(message, code=1):
    sys.stderr.write(f"read-doc-profile: {message}\n")
    sys.exit(code)


profile_prefix = f"read_profiles.{profile}."
section_key = f"{profile_prefix}sections[]"
all_profile_keys = []
sections = []

with open(parsed_path, encoding="utf-8") as parsed:
    for raw in parsed:
        line = raw.rstrip("\n")
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("read_profiles."):
            all_profile_keys.append(key)
        if key == section_key:
            if value == "":
                fail(f"profile contains a blank section name: {profile}")
            sections.append(value)

if not all_profile_keys:
    fail("read_profiles frontmatter is required")
if not sections:
    known = sorted(
        {
            key[len("read_profiles."):].split(".", 1)[0]
            for key in all_profile_keys
            if key.startswith("read_profiles.") and "." in key[len("read_profiles."):]
        }
    )
    detail = f"; known profiles: {', '.join(known)}" if known else ""
    fail(f"profile not found or has no sections: {profile}{detail}")

for section_name in sections:
    print(section_name)
PY

count=0
failed=0
section_files=()
while IFS= read -r section_name; do
  [ -n "$section_name" ] || continue
  count=$((count + 1))
  out_file="$SECTIONS_DIR/$count.md"
  err_file="$SECTIONS_DIR/$count.err"
  if bash "$SECTION_READER" "$1" "$section_name" >"$out_file" 2>"$err_file"; then
    section_files+=("$out_file")
  else
    sed 's/^read-doc-section:/read-doc-profile:/' "$err_file" >&2
    failed=1
  fi
done < "$SECTIONS"

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
