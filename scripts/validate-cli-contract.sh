#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# validate-cli-contract.sh - Validate a *.cli-contract.md file against the
# WS5 CLI-contract schema.
#
# Usage: bash scripts/validate-cli-contract.sh <path-to-cli-contract.md>
#
# Output format:
#   Summary line: `CLI-CONTRACT-DRIFT: <N> issue(s) in <path>`
#   One indented line per issue: `  - <message>`
#
# Exit codes:
#   0 - valid
#   1 - one or more contract violations (issues printed to stderr)
#   2 - invocation problem (file missing, unreadable, etc.)

set -uo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <path-to-cli-contract.md>" >&2; exit 2; }
contract="$1"
[ -f "$contract" ] || { echo "Not a file: $contract" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || {
  echo "validate-cli-contract.sh: yaml-lite helper not found at $YAML_LITE" >&2
  exit 2
}
PARSED_FILE=$(mktemp)
PARSER_ERR=$(mktemp)
trap 'rm -f "$PARSED_FILE" "$PARSER_ERR"' EXIT

if bash "$YAML_LITE" frontmatter "$contract" >"$PARSED_FILE" 2>"$PARSER_ERR"; then
  parser_failed=0
else
  parser_failed=1
fi

python3 - "$contract" "$PARSED_FILE" "$PARSER_ERR" "$parser_failed" <<'PYEOF'
import re
import sys

path = sys.argv[1]
parsed_path = sys.argv[2]
parser_err_path = sys.argv[3]
parser_failed = sys.argv[4] == "1"

with open(path, encoding="utf-8") as handle:
    text = handle.read()

issues = []

# Frontmatter delimiter check - file must start with --- and have a closing ---.
parts = re.split(r'^---\s*$', text, maxsplit=2, flags=re.MULTILINE)
if len(parts) < 3 or parts[0].strip() != "":
    issues.append("missing or malformed frontmatter delimiters (file must start with --- and contain a closing ---)")
    body = text
else:
    body = parts[2]

fm = {}
lists = {}
list_maps = {}

if parser_failed:
    with open(parser_err_path, encoding="utf-8") as err:
        detail = err.read().strip()
    issues.append("frontmatter is not valid YAML-lite" + (f": {detail}" if detail else ""))
else:
    with open(parsed_path, encoding="utf-8") as parsed:
        for raw in parsed:
            line = raw.rstrip("\n")
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            match = re.fullmatch(r"([A-Za-z0-9_-]+)\[(\d+)\]\.([A-Za-z0-9_-]+)", key)
            if match:
                parent, index, child = match.groups()
                list_maps.setdefault(parent, {}).setdefault(int(index), {})[child] = value
                continue
            if key.endswith("[]"):
                lists.setdefault(key[:-2], []).append(value)
                continue
            fm[key] = value

for key, values in lists.items():
    fm[key] = values
for key, by_index in list_maps.items():
    fm[key] = [by_index[index] for index in sorted(by_index)]

# Required frontmatter fields - present AND non-empty.
for field in ("script", "version", "invokers", "related-designs"):
    if field not in fm:
        issues.append(f"missing required frontmatter field: {field}")
    elif fm[field] in (None, "", "[]", [], {}):
        issues.append(f"frontmatter field '{field}' is empty (must have a non-empty value)")

# version must be semver-light (major.minor).
if "version" in fm and fm["version"] not in (None, "", "[]"):
    vstr = str(fm["version"])
    if not re.fullmatch(r"\d+\.\d+", vstr):
        issues.append(f"version must be semver-light (major.minor); got '{vstr}'")

# invokers must be a list; every entry must be a mapping with 'type' in the closed enum.
ALLOWED_TYPES = {"skill", "script", "hook", "plugin", "developer"}
if "invokers" in fm and fm["invokers"] not in (None, "", "[]", [], {}):
    if not isinstance(fm["invokers"], list):
        issues.append(f"invokers: must be a YAML list; got {type(fm['invokers']).__name__}")
    else:
        for index, entry in enumerate(fm["invokers"]):
            if not isinstance(entry, dict):
                issues.append(f"invokers[{index}]: must be a mapping with a 'type:' field; got {type(entry).__name__}")
                continue
            if "type" not in entry:
                issues.append(f"invokers[{index}]: missing required 'type:' field")
                continue
            invoker_type = entry["type"]
            if invoker_type not in ALLOWED_TYPES:
                issues.append(
                    f"invokers[{index}]: type '{invoker_type}' not in closed enum "
                    f"(expected one of: {', '.join(sorted(ALLOWED_TYPES))})"
                )

# Body section checks.
required_sections = ("## Surface", "## Protocol", "## Test surface", "## Versioning")
for section in required_sections:
    if section not in body:
        issues.append(f"missing required body section: {section}")

required_subsections = ("### Arguments", "### Exit codes", "### Side effects")
for subsection in required_subsections:
    if subsection not in body:
        issues.append(f"missing required sub-section under ## Protocol: {subsection}")

# Test surface must contain at least one bullet-list assertion.
ts_match = re.search(r"^## Test surface\s*$(.*?)(?=^## |\Z)", body, re.MULTILINE | re.DOTALL)
if ts_match:
    if not re.search(r"^- ", ts_match.group(1), re.MULTILINE):
        issues.append("## Test surface has no bullet-list assertions")

if not issues:
    sys.exit(0)

print(f"CLI-CONTRACT-DRIFT: {len(issues)} issue(s) in {path}", file=sys.stderr)
for message in issues:
    print(f"  - {message}", file=sys.stderr)
sys.exit(1)
PYEOF
