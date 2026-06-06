#!/usr/bin/env bash
# owner: document-taxonomy
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "Usage: scripts/validate-template-taxonomy.sh [catalog-path]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
CATALOG="${1:-$ROOT/docs/templates/document-shapes.yaml}"

[ "$(command -v python3 2>/dev/null)" ] || { echo "validate-template-taxonomy: python3 not found in PATH" >&2; exit 2; }
[ -f "$YAML_LITE" ] || { echo "validate-template-taxonomy: yaml-lite helper not found at $YAML_LITE" >&2; exit 2; }
[ -f "$CATALOG" ] || { echo "validate-template-taxonomy: catalog not found: $CATALOG" >&2; exit 2; }

CATALOG_PARSED="$(mktemp)"
CATALOG_ERR="$(mktemp)"
trap 'rm -f "$CATALOG_PARSED" "$CATALOG_ERR"' EXIT

if ! bash "$YAML_LITE" file "$CATALOG" >"$CATALOG_PARSED" 2>"$CATALOG_ERR"; then
  echo "validate-template-taxonomy: invalid shape catalog: $CATALOG" >&2
  sed 's/^/validate-template-taxonomy: /' "$CATALOG_ERR" >&2
  exit 2
fi

python3 - "$ROOT" "$CATALOG" "$CATALOG_PARSED" "$YAML_LITE" <<'PY'
import os
import re
import subprocess
import sys

root, catalog_path, parsed_catalog_path, yaml_lite = sys.argv[1:5]


def normalize_heading(raw):
    return re.sub(r"\s+", " ", raw.strip()).casefold()


def semantic_key(raw):
    key = normalize_heading(raw)
    key = re.sub(r"[^a-z0-9]+", "-", key)
    return key.strip("-")


def display_heading(raw):
    raw = re.sub(r"[ \t]+#+[ \t]*$", "", raw)
    return raw.strip()


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


def read_frontmatter_shape(path):
    result = subprocess.run(
        ["bash", yaml_lite, "frontmatter", path],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return read_frontmatter_shape_literal(path)
    for key, value in parse_line_text(result.stdout):
        if key == "document-shape":
            return value
    return None


def read_frontmatter_shape_literal(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    match = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.DOTALL)
    if not match:
        return None
    for raw in match.group(1).splitlines():
        line = raw.strip()
        shape_match = re.match(r"^document-shape:[ \t]*([A-Za-z0-9_-]+)[ \t]*$", line)
        if shape_match:
            return shape_match.group(1)
    return None


def parse_line_text(text):
    rows = []
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        rows.append((key, value))
    return rows


counts = {"ok": 0, "warning": 0, "lifecycle-required": 0, "failure": 0}


def emit(severity, shape, template, key, heading, message, fix):
    counts[severity] += 1
    if severity == "ok":
        return
    print(
        "TEMPLATE-TAXONOMY: "
        f"{severity}: shape={shape or '-'} template={template or '-'} "
        f"key={key or '-'} heading={heading or '-'} :: {message} :: fix={fix}",
        file=sys.stderr,
    )


def template_abs_path(template):
    if os.path.isabs(template):
        return template
    return os.path.abspath(os.path.join(root, template))


def required_value(section):
    return section.get("required", "").strip().casefold()


def catalog_lookup_tokens(section):
    key = section.get("key", "")
    if key:
        yield key, "key", key
    for alias in section.get("aliases", []):
        alias_key = semantic_key(alias)
        if alias_key:
            yield alias_key, "alias", alias


def check_lookup_token_collisions(shape_name, template, sections):
    seen = {}
    for section in sections:
        section_key = section.get("key", "")
        for token, kind, raw in catalog_lookup_tokens(section):
            previous = seen.get(token)
            if previous:
                previous_kind, previous_section_key, previous_raw = previous
                emit(
                    "failure",
                    shape_name,
                    template,
                    token,
                    raw,
                    "duplicate catalog lookup token "
                    f"also used by {previous_kind}={previous_raw} "
                    f"on section {previous_section_key}",
                    "deduplicate section keys and aliases in document-shapes.yaml",
                )
                continue
            seen[token] = (kind, section_key or "-", raw)


shapes = parse_catalog(parsed_catalog_path)
if not shapes:
    emit(
        "failure",
        "-",
        os.path.relpath(catalog_path, root) if os.path.isabs(catalog_path) else catalog_path,
        "-",
        "-",
        "shape catalog contains no document_shapes entries",
        "add document_shapes entries to the catalog",
    )

for shape_name in sorted(shapes):
    shape = shapes[shape_name]
    template = shape.get("template", "")
    sections = shape.get("sections", [])
    check_lookup_token_collisions(shape_name, template, sections)
    if not template:
        emit(
            "failure",
            shape_name,
            "-",
            "-",
            "-",
            "shape is missing a template path",
            "add template: docs/templates/<name>.md to the shape",
        )
        continue

    template_path = template_abs_path(template)
    if not os.path.isfile(template_path):
        emit(
            "failure",
            shape_name,
            template,
            "-",
            "-",
            "cataloged template path is missing",
            "fix the template path or add the missing template file",
        )
        continue

    frontmatter_shape = read_frontmatter_shape(template_path)
    if frontmatter_shape and frontmatter_shape != shape_name:
        emit(
            "failure",
            shape_name,
            template,
            "document-shape",
            frontmatter_shape,
            "template document-shape does not match catalog shape",
            f"set document-shape: {shape_name} or move the template to the matching shape",
        )
    elif not frontmatter_shape:
        emit(
            "warning",
            shape_name,
            template,
            "document-shape",
            "-",
            "template has no document-shape frontmatter",
            f"add document-shape: {shape_name} when this template is catalog-owned",
        )
    else:
        emit("ok", shape_name, template, "document-shape", frontmatter_shape, "", "")

    headings = scan_headings(template_path)
    used_heading_keys = set()
    claimed_heading_keys = {}
    matched_positions = []

    if not sections:
        emit(
            "failure",
            shape_name,
            template,
            "-",
            "-",
            "shape has no sections",
            "add at least one section record with key, heading, and required",
        )

    for section in sections:
        key = section.get("key", "")
        heading = section.get("heading", "")
        required = required_value(section)
        aliases = section.get("aliases", [])
        if not key or not heading or required not in {"yes", "no"}:
            emit(
                "failure",
                shape_name,
                template,
                key,
                heading,
                "section record is missing key, heading, or required yes/no",
                "repair the section record in document-shapes.yaml",
            )
            continue

        canonical_key = normalize_heading(heading)
        alias_keys = {normalize_heading(alias) for alias in aliases if alias}
        matches = [
            item
            for item in headings
            if item["level"] == 2 and item["match_key"] in ({canonical_key} | alias_keys)
        ]

        if len(matches) > 1:
            locations = ", ".join(str(item["line"]) for item in matches)
            emit(
                "failure",
                shape_name,
                template,
                key,
                heading,
                f"duplicate semantic heading match at lines {locations}",
                "deduplicate the template heading or narrow the alias set",
            )
            continue

        if not matches:
            if required == "yes":
                emit(
                    "failure",
                    shape_name,
                    template,
                    key,
                    heading,
                    "required catalog section is missing from template",
                    "restore the heading, add an alias-backed lifecycle path, or update the catalog intentionally",
                )
            else:
                emit(
                    "warning",
                    shape_name,
                    template,
                    key,
                    heading,
                    "optional catalog section is missing from template",
                    "restore the heading or remove the optional catalog entry intentionally",
                )
            continue

        match = matches[0]
        claiming_key = claimed_heading_keys.get(match["match_key"])
        if claiming_key:
            emit(
                "failure",
                shape_name,
                template,
                key,
                match["heading"],
                f"template heading already claimed by catalog section {claiming_key}",
                "give each catalog section a distinct canonical heading or alias-backed heading",
            )
            continue
        claimed_heading_keys[match["match_key"]] = key
        used_heading_keys.add(match["match_key"])
        matched_positions.append((len(matched_positions), match["line"], key))
        if match["match_key"] == canonical_key:
            emit("ok", shape_name, template, key, match["heading"], "", "")
        else:
            emit(
                "lifecycle-required",
                shape_name,
                template,
                key,
                match["heading"],
                "section resolved through alias rather than canonical heading",
                "record lifecycle intent or update the canonical heading deliberately",
            )

    lines_in_catalog_order = [line for _, line, _ in matched_positions]
    if lines_in_catalog_order != sorted(lines_in_catalog_order):
        emit(
            "warning",
            shape_name,
            template,
            "-",
            "-",
            "cataloged section order differs from template order",
            "reorder the catalog sections or the template headings deliberately",
        )

    for item in headings:
        if item["match_key"] in used_heading_keys:
            continue
        if item["level"] == 1:
            emit(
                "warning",
                shape_name,
                template,
                "-",
                item["heading"],
                "template H1 title is not cataloged",
                "review only; H1 titles are template-owned",
            )
        elif item["level"] >= 2:
            emit(
                "warning",
                shape_name,
                template,
                "-",
                item["heading"],
                "template heading is not mapped in the shape catalog",
                "catalog the section if agents should retrieve it, otherwise leave as template-owned guidance",
            )

print(
    "TEMPLATE-TAXONOMY-SUMMARY: "
    f"ok={counts['ok']} warnings={counts['warning']} "
    f"lifecycle-required={counts['lifecycle-required']} failures={counts['failure']}",
    file=sys.stderr,
)

sys.exit(1 if counts["failure"] else 0)
PY
