#!/usr/bin/env bash
# owner: document-access
set -euo pipefail

[ "$#" -eq 1 ] || { echo "Usage: $0 <markdown-file>" >&2; exit 2; }
[ -f "$1" ] || { echo "explore-doc: file not found: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
CATALOG="$ROOT/docs/templates/document-shapes.yaml"
[ -f "$YAML_LITE" ] || { echo "explore-doc: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "explore-doc: shape catalog not found at $CATALOG" >&2; exit 1; }

CATALOG_PARSED="$(mktemp)"
FRONTMATTER_PARSED="$(mktemp)"
CATALOG_ERR="$(mktemp)"
FRONTMATTER_ERR="$(mktemp)"
trap 'rm -f "$CATALOG_PARSED" "$FRONTMATTER_PARSED" "$CATALOG_ERR" "$FRONTMATTER_ERR"' EXIT

if ! bash "$YAML_LITE" file "$CATALOG" >"$CATALOG_PARSED" 2>"$CATALOG_ERR"; then
  echo "explore-doc: invalid shape catalog" >&2
  sed 's/^/explore-doc: /' "$CATALOG_ERR" >&2
  exit 1
fi

if ! bash "$YAML_LITE" frontmatter "$1" >"$FRONTMATTER_PARSED" 2>"$FRONTMATTER_ERR"; then
  : >"$FRONTMATTER_PARSED"
fi

python3 - "$ROOT" "$1" "$CATALOG_PARSED" "$FRONTMATTER_PARSED" <<'PY'
import os
import re
import sys

root, doc_path, catalog_path, frontmatter_path = sys.argv[1:5]


def fail(message, code=1):
    sys.stderr.write(f"explore-doc: {message}\n")
    sys.exit(code)


def normalize_heading(raw):
    return re.sub(r"\s+", " ", raw.strip()).casefold()


def semantic_key(raw):
    key = normalize_heading(raw)
    key = re.sub(r"[^a-z0-9]+", "-", key)
    return key.strip("-")


def parse_line_file(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            rows.append((key, value))
    return rows


def parse_catalog(path):
    shapes = {}
    row_re = re.compile(r"^document_shapes\.([^.]+)\.(.+)$")
    section_re = re.compile(r"^sections\[(\d+)\]\.(.+)$")
    for key, value in parse_line_file(path):
        match = row_re.match(key)
        if not match:
            continue
        shape_name, rest = match.groups()
        shape = shapes.setdefault(shape_name, {"sections": []})
        section_match = section_re.match(rest)
        if section_match:
            index = int(section_match.group(1))
            field = section_match.group(2)
            while len(shape["sections"]) <= index:
                shape["sections"].append({"aliases": []})
            section = shape["sections"][index]
            if field == "aliases[]":
                section.setdefault("aliases", []).append(value)
            else:
                section[field] = value
        else:
            shape[rest] = value
    return shapes


def document_shape_from_frontmatter(path):
    for key, value in parse_line_file(path):
        if key == "document-shape":
            return value
    return None


def infer_shape(doc, shapes):
    rel = os.path.relpath(os.path.abspath(doc), root)
    rel = os.path.normpath(rel)
    for shape_name, shape in shapes.items():
        template = shape.get("template")
        if template and os.path.normpath(template) == rel:
            return shape_name
    return None


def display_heading(raw):
    raw = re.sub(r"[ \t]+#+[ \t]*$", "", raw)
    return raw.strip()


def scan_headings(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    frontmatter = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.DOTALL)
    if frontmatter:
        text = text[frontmatter.end():]
    lines = text.splitlines()
    heading_re = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*$")
    fence_re = re.compile(r"^[ \t]{0,3}(```+|~~~+)")
    headings = []
    in_fence = False
    fence_marker = ""
    fence_length = 0
    for index, line in enumerate(lines):
        fence = fence_re.match(line)
        if fence:
            marker = fence.group(1)
            marker_family = marker[0]
            if not in_fence:
                in_fence = True
                fence_marker = marker_family
                fence_length = len(marker)
            elif marker_family == fence_marker and len(marker) >= fence_length:
                in_fence = False
                fence_marker = ""
                fence_length = 0
            continue
        if in_fence:
            continue
        match = heading_re.match(line)
        if not match:
            continue
        title = display_heading(match.group(2))
        headings.append(
            {
                "line": index + 1,
                "level": len(match.group(1)),
                "heading": title,
                "match_key": normalize_heading(title),
                "semantic_key": semantic_key(title),
            }
        )
    return headings


def heading_matches(headings, names):
    keys = {normalize_heading(name) for name in names if name}
    return [heading for heading in headings if heading["match_key"] in keys]


shapes = parse_catalog(catalog_path)
frontmatter_shape = document_shape_from_frontmatter(frontmatter_path)
shape_name = frontmatter_shape or infer_shape(doc_path, shapes) or "unknown"
shape = shapes.get(shape_name, {"sections": []})
headings = scan_headings(doc_path)
emitted_heading_keys = set()
index = 0

print(f"document-shape={shape_name}")

for section in shape.get("sections", []):
    key = section.get("key")
    heading = section.get("heading")
    if not key or not heading:
        fail(f"shape {shape_name} has an invalid section entry")
    names = [heading] + section.get("aliases", [])
    matches = heading_matches(headings, names)
    if len(matches) > 1:
        locations = ", ".join(str(match["line"]) for match in matches)
        fail(f"semantic key is ambiguous: {key} (lines {locations})")
    if not matches:
        print(f"warning[]=missing-section:{key}:{heading}")
        continue
    match = matches[0]
    emitted_heading_keys.add(match["match_key"])
    print(f"section[{index}].key={key}")
    for alias in section.get("aliases", []):
        alias_key = semantic_key(alias)
        if alias_key:
            print(f"section[{index}].alias={alias_key}")
    print(f"section[{index}].heading={match['heading']}")
    print(f"section[{index}].level={match['level']}")
    print("section[%d].source=shape" % index)
    index += 1

for heading in headings:
    if heading["match_key"] in emitted_heading_keys:
        continue
    print(f"section[{index}].key={heading['semantic_key']}")
    print(f"section[{index}].heading={heading['heading']}")
    print(f"section[{index}].level={heading['level']}")
    print("section[%d].source=heading" % index)
    print(f"warning[]=unmapped-heading:{heading['heading']}")
    index += 1
PY
