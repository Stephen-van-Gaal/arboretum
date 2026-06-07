#!/usr/bin/env bash
# owner: document-access
set -euo pipefail

[ "$#" -eq 2 ] || { echo "Usage: $0 <markdown-file> <section-heading>" >&2; exit 2; }
[ -f "$1" ] || { echo "read-doc-section: file not found: $1" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- token accounting (advisory; never affects output/exit) ---
if [ -f "${ROOT}/scripts/lib/token-ledger.sh" ]; then
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/token-ledger.sh"
  _tok_capture() { ARBORETUM_BUCKET=on-demand ledger_append reads "${1}@${2}" "${3}" 2>/dev/null || true; }
fi

# Capture the section output, print it byte-for-byte unchanged, then ledger it.
out="$(python3 - "$1" "$2" <<'PY'
import re
import sys

path = sys.argv[1]
target = sys.argv[2]


def fail(message, code=1):
    sys.stderr.write(f"read-doc-section: {message}\n")
    sys.exit(code)


with open(path, encoding="utf-8") as handle:
    text = handle.read()

frontmatter = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", text, re.DOTALL)
if frontmatter:
    text = text[frontmatter.end():]

lines = text.splitlines()
heading_re = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*$")
fence_re = re.compile(r"^[ \t]{0,3}(```+|~~~+)")


def display_heading(raw):
    raw = re.sub(r"[ \t]+#+[ \t]*$", "", raw)
    return raw.strip()


def match_key(raw):
    return re.sub(r"\s+", " ", raw.strip()).casefold()


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
    level = len(match.group(1))
    title = display_heading(match.group(2))
    headings.append({"line": index, "level": level, "title": title, "key": match_key(title)})

target_key = match_key(target)
matches = [heading for heading in headings if heading["key"] == target_key]
if not matches:
    fail(f"section not found: {target}")
if len(matches) > 1:
    locations = ", ".join(str(match["line"] + 1) for match in matches)
    fail(f"duplicate section heading is ambiguous: {target} (lines {locations})")

selected = matches[0]
start = selected["line"]
end = len(lines)
for heading in headings:
    if heading["line"] <= start:
        continue
    if heading["level"] <= selected["level"]:
        end = heading["line"]
        break

section = "\n".join(lines[start:end]).strip()
if not section:
    fail(f"section not found: {target}")

sys.stdout.write(section)
sys.stdout.write("\n")
PY
)"

# Print the captured section byte-for-byte (Python emitted section + one trailing
# newline; the command substitution stripped that newline, so re-add exactly one).
printf '%s\n' "$out"
# Advisory ledger emit; must never change this script's exit code. The trailing
# `&& cmd` form would return 1 (and trip `set -e`) when the ledger lib is absent
# and `_tok_capture` is undefined, so gate it as a non-failing statement.
if [ "$(type -t _tok_capture)" = function ]; then
  # Count payload bytes (not characters): ${#out} undercounts multi-byte UTF-8,
  # skewing the ledger's `bytes`/`est_tokens`. wc -c is byte-exact + locale-safe.
  _b="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  _tok_capture "$1" "$2" "${_b:-0}"
fi
