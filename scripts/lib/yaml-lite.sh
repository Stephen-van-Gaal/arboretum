#!/usr/bin/env bash
# owner: pipeline-contracts-template
# yaml-lite.sh - Shared parser for Arboretum's constrained YAML/frontmatter subset.

yaml_lite_parse() {
  local mode="$1"
  local file="$2"

  PYTHONUTF8=1 python3 - "$mode" "$file" <<'PY'
import os
import re
import sys

mode = sys.argv[1]
path = sys.argv[2]


def die(message, code=1):
    sys.stderr.write(f"yaml-lite: {message}\n")
    sys.exit(code)


def starts_quoted_scalar(text_line, index):
    """Return true when a quote starts a YAML-lite quoted scalar token."""
    prefix = text_line[:index].rstrip()
    if not prefix:
        return True
    previous = prefix[-1]
    if previous in ":,{[":
        return True
    if previous == ",":
        return True
    return previous == "-" and prefix[:-1].strip() == ""


def has_closing_quote(text_line, index, quote_char):
    escaped = False
    for char in text_line[index + 1:]:
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote_char == '"':
            escaped = True
            continue
        if char == quote_char:
            return True
    return False


def starts_quote_span(text_line, index, quote_char):
    if starts_quoted_scalar(text_line, index):
        return True
    return quote_char == '"' and has_closing_quote(text_line, index, quote_char)


if mode not in {"file", "frontmatter"}:
    die("mode must be 'file' or 'frontmatter'", 2)
if not os.path.isfile(path):
    die(f"file not found: {path}", 2)

with open(path, encoding="utf-8") as handle:
    text = handle.read()

if mode == "frontmatter":
    match = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.DOTALL)
    if not match:
        die(f"missing leading frontmatter block: {path}")
    text = match.group(1)


def strip_comment(line):
    quote = None
    escaped = False
    output = []
    for index, char in enumerate(line):
        if escaped:
            output.append(char)
            escaped = False
            continue
        if char == "\\" and quote == '"':
            output.append(char)
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            output.append(char)
            continue
        if char in ("'", '"') and starts_quote_span(line, index, char):
            quote = char
            output.append(char)
            continue
        if char == "#":
            break
        output.append(char)
    if quote:
        die("unterminated quoted scalar")
    return "".join(output).rstrip()


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def find_unquoted(text_line, target):
    quote = None
    escaped = False
    for index, char in enumerate(text_line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote == '"':
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"') and starts_quote_span(text_line, index, char):
            quote = char
            continue
        if char == target:
            return index
    return -1


def split_key_value(text_line, source_line):
    index = find_unquoted(text_line, ":")
    if index < 0:
        die(f"expected key/value pair on line {source_line}")
    key = unquote(text_line[:index].strip())
    value = text_line[index + 1:].strip()
    if not key:
        die(f"empty key on line {source_line}")
    return key, value


def looks_like_mapping_item(item):
    index = find_unquoted(item, ":")
    if index < 0:
        return False
    after = item[index + 1:]
    return after == "" or after[:1].isspace()


def split_top_level(inner, source_line):
    items = []
    quote = None
    escaped = False
    curly_depth = 0
    square_depth = 0
    current = []

    for index, char in enumerate(inner):
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\" and quote == '"':
            current.append(char)
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            current.append(char)
            continue
        if char in ("'", '"') and starts_quote_span(inner, index, char):
            quote = char
            current.append(char)
            continue
        if char == "{":
            curly_depth += 1
            current.append(char)
            continue
        if char == "}":
            if curly_depth == 0:
                die(f"unbalanced flow mapping on line {source_line}")
            curly_depth -= 1
            current.append(char)
            continue
        if char == "[":
            square_depth += 1
            current.append(char)
            continue
        if char == "]":
            if square_depth == 0:
                die(f"unbalanced flow list on line {source_line}")
            square_depth -= 1
            current.append(char)
            continue
        if char == "," and curly_depth == 0 and square_depth == 0:
            items.append("".join(current).strip())
            current = []
            continue
        current.append(char)

    if quote:
        die(f"unterminated quoted flow value on line {source_line}")
    if curly_depth != 0:
        die(f"unterminated flow mapping on line {source_line}")
    if square_depth != 0:
        die(f"unterminated flow list on line {source_line}")

    items.append("".join(current).strip())
    return [item for item in items if item]


def flow_inner(flow_text, opener, closer, source_line, kind):
    inner = flow_text.strip()
    if not (inner.startswith(opener) and inner.endswith(closer)):
        die(f"unsupported flow {kind} on line {source_line}")
    return inner[1:-1].strip()


def split_flow_items(flow_text, source_line, opener="{", closer="}", kind="mapping"):
    inner = flow_inner(flow_text, opener, closer, source_line, kind)
    if not inner:
        return []
    return split_top_level(inner, source_line)


def parse_flow_mapping(parent_path, value, source_line):
    rows = []
    for item in split_flow_items(value, source_line):
        key, sub_value = split_key_value(item, source_line)
        if sub_value.startswith("{"):
            die(f"unsupported nested flow mapping on line {source_line}")
        if sub_value.startswith("["):
            rows.extend(parse_flow_sequence(append_path(parent_path, key), sub_value, source_line))
        else:
            rows.append((f"{parent_path}.{key}", unquote(sub_value)))
    return rows


def append_path(parent_path, key):
    return f"{parent_path}.{key}" if parent_path else key


def parse_flow_sequence(parent_path, value, source_line):
    rows = []
    mapping_index = 0
    for item in split_flow_items(value, source_line, "[", "]", "list"):
        if item.startswith("{"):
            if not item.endswith("}"):
                die(f"unterminated flow mapping on line {source_line}")
            item_path = f"{parent_path}[{mapping_index}]"
            mapping_index += 1
            rows.extend(parse_flow_mapping(item_path, item, source_line))
            continue
        if item.startswith("["):
            die(f"unsupported nested flow list on line {source_line}")
        rows.append((f"{parent_path}[]", unquote(item)))
    return rows


def block_scalar_style(value):
    # YAML block scalar header: '>' (folded) or '|' (literal), with at most one
    # chomping indicator ('+'/'-') and at most one explicit indentation digit
    # (1-9), in either order. yaml-lite folds every block scalar to a single-line
    # value (the key=value line protocol cannot carry newlines), so the indicators
    # are accepted but not separately honored. A malformed header like '>++' is
    # not treated as a block scalar (and so fails normal parsing) rather than
    # being silently accepted.
    return bool(re.match(r"^[|>]([1-9][+-]?|[+-][1-9]?|)$", value))


def render_block_scalar(block_lines):
    # Fold block-scalar content to one line: strip each line, drop blank lines,
    # join with single spaces. Lossy for literal '|' newlines by design — the
    # output is a flat key=value line protocol.
    parts = [line.strip() for line in block_lines if line.strip() != ""]
    return " ".join(parts)


def consume_block_scalar(lines, start, min_indent):
    # Consume a block scalar's continuation lines: blanks are kept (folded out
    # later), a line whose leading whitespace contains a tab is rejected to match
    # the parser's no-tab-indentation rule, and the block ends at the first line
    # indented at or below min_indent. Returns (folded_value, next_index).
    collected = []
    i = start
    while i < len(lines):
        nxt = lines[i]
        # Reject tabs in leading whitespace BEFORE the blank-line branch, so a
        # tab-only "blank" line (e.g. "\t") is rejected too — matching YL-15 and
        # the parser's global no-tab-indentation rule. Spaces-only blanks pass.
        lead = nxt[: len(nxt) - len(nxt.lstrip())]
        if "\t" in lead:
            die(f"tabs are not supported for indentation on line {i + 1}")
        if nxt.strip() == "":
            collected.append("")
            i += 1
            continue
        if len(nxt) - len(nxt.lstrip(" ")) <= min_indent:
            break
        collected.append(nxt)
        i += 1
    return render_block_scalar(collected), i


rows = []
contexts = []
list_indexes = {}

source_lines = text.splitlines()
line_index = 0
while line_index < len(source_lines):
    raw = source_lines[line_index]
    lineno = line_index + 1
    line_index += 1
    if "\t" in raw[: len(raw) - len(raw.lstrip())]:
        die(f"tabs are not supported for indentation on line {lineno}")
    if raw.strip() == "" or raw.lstrip().startswith("#"):
        continue

    without_comment = strip_comment(raw)
    if without_comment.strip() == "":
        continue

    indent = len(without_comment) - len(without_comment.lstrip(" "))
    if indent % 2 != 0:
        die(f"unsupported indentation on line {lineno}")

    stripped = without_comment.strip()
    while contexts and indent <= contexts[-1]["indent"]:
        contexts.pop()

    if indent > 0:
        if not contexts:
            die(f"indented key without mapping parent on line {lineno}")
        expected_indent = contexts[-1]["indent"] + 2
        if indent != expected_indent:
            die(f"unsupported indentation on line {lineno}")

    parent_path = contexts[-1]["path"] if contexts else None

    if stripped.startswith("- "):
        if parent_path is None:
            die(f"list item without parent on line {lineno}")
        item = stripped[2:].strip()
        if not item:
            die(f"empty list item on line {lineno}")
        if looks_like_mapping_item(item):
            index = list_indexes.get(parent_path, 0)
            list_indexes[parent_path] = index + 1
            item_path = f"{parent_path}[{index}]"
            key, value = split_key_value(item, lineno)
            if block_scalar_style(value):
                value_text, line_index = consume_block_scalar(source_lines, line_index, indent + 2)
                rows.append((append_path(item_path, key), value_text))
            elif value.startswith("{"):
                for row in parse_flow_mapping(append_path(item_path, key), value, lineno):
                    rows.append(row)
            elif value.startswith("["):
                for row in parse_flow_sequence(append_path(item_path, key), value, lineno):
                    rows.append(row)
            else:
                rows.append((append_path(item_path, key), unquote(value)))
            contexts.append({"indent": indent, "path": item_path})
        else:
            rows.append((f"{parent_path}[]", unquote(item)))
        continue

    key, value = split_key_value(stripped, lineno)
    path_key = append_path(parent_path, key)
    if value == "":
        contexts.append({"indent": indent, "path": path_key})
        continue
    if block_scalar_style(value):
        value_text, line_index = consume_block_scalar(source_lines, line_index, indent)
        rows.append((path_key, value_text))
        continue
    if value.startswith("{"):
        for row in parse_flow_mapping(path_key, value, lineno):
            rows.append(row)
        continue
    if value.startswith("["):
        for row in parse_flow_sequence(path_key, value, lineno):
            rows.append(row)
        continue
    rows.append((path_key, unquote(value)))

for key, value in rows:
    print(f"{key}={value}")
PY
}

yaml_lite_main() {
  if [ "$#" -ne 2 ]; then
    echo "yaml-lite: usage: yaml-lite.sh file|frontmatter path" >&2
    return 2
  fi
  yaml_lite_parse "$1" "$2"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  yaml_lite_main "$@"
fi
