#!/usr/bin/env bash
# owner: test-infrastructure
# read-test-config.sh — Read & validate a project's testing-shape declaration
# off a test-infrastructure.spec.md frontmatter block (per
# docs/superpowers/specs/2026-05-30-testing-shape-design.md). Prints key=value
# lines on success (exit 0); exits 2 on missing required field, invalid enum,
# or malformed/absent frontmatter; exits 1 on usage error.
#
# Required field:
#   - default-command: <non-empty string> — the default-safe test command (exit 0 == green)
# Optional fields:
#   - runner: <string>           (informational)
#   - layout: <string>           (informational; e.g. by-feature | by-tier)
#   - tiers-via: markers | directories
#   - opt-in-commands: <object; sub-keys in {live, costly}>
set -euo pipefail
[ "$#" -eq 1 ] || { echo "Usage: $0 <test-infrastructure-spec-file>" >&2; exit 1; }
[ -f "$1" ] || { echo "test-infrastructure spec not found: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-test-config: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

PARSED_FILE=$(mktemp)
PARSER_ERR=$(mktemp)
trap 'rm -f "$PARSED_FILE" "$PARSER_ERR"' EXIT

if ! bash "$YAML_LITE" frontmatter "$1" >"$PARSED_FILE" 2>"$PARSER_ERR"; then
    echo "read-test-config: invalid or missing frontmatter" >&2
    sed 's/^/read-test-config: /' "$PARSER_ERR" >&2
    exit 2
fi

python3 - "$1" "$PARSED_FILE" <<'PY'
import sys

def unquote(s):
    s = s.strip()
    if (s.startswith("'") and s.endswith("'")) or (s.startswith('"') and s.endswith('"')):
        return s[1:-1]
    return s

parsed_path = sys.argv[2]
fm = {}
opt_in = {}
opt_in_order = []

with open(parsed_path, encoding="utf-8") as parsed:
    for raw in parsed:
        line = raw.rstrip("\n")
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("opt-in-commands."):
            subkey = key.split(".", 1)[1]
            if subkey not in opt_in:
                opt_in_order.append(subkey)
            opt_in[subkey] = value
        elif key.startswith("tiers-via."):
            fm["tiers-via"] = {}
        elif key == "opt-in-commands":
            fm[key] = value
        elif key in {"default-command", "runner", "layout", "tiers-via"}:
            fm[key] = value

if opt_in:
    fm["opt-in-commands"] = opt_in

# Required: default-command (non-empty scalar).
if "default-command" not in fm:
    sys.stderr.write("read-test-config: missing required field: default-command\n")
    sys.exit(2)
dc = fm["default-command"]
if isinstance(dc, dict) or not unquote(dc):
    sys.stderr.write("read-test-config: default-command must be a non-empty string\n")
    sys.exit(2)
dc = unquote(dc)
# Reject an unfilled angle-bracket placeholder (the template ships
# `default-command: <command that runs ...>`). A non-empty placeholder would
# otherwise pass and be eval'd verbatim by the consumer; treat it as not-yet-
# declared so the gate falls back / warns instead.
if dc.startswith("<") and dc.endswith(">"):
    sys.stderr.write(
        "read-test-config: default-command is still an unfilled <placeholder> — fill it in\n"
    )
    sys.exit(2)
fm["default-command"] = dc

# Optional enum: tiers-via. Must be a scalar in the enum — a dict-shaped value
# is a malformed declaration (it would otherwise skip validation and print
# tiers-via.<subkey>= lines with exit 0).
TIERS_VIA_ENUM = {"markers", "directories"}
if "tiers-via" in fm:
    if isinstance(fm["tiers-via"], dict):
        sys.stderr.write(
            "read-test-config: tiers-via must be a scalar (markers|directories), got an object\n"
        )
        sys.exit(2)
    tv = unquote(fm["tiers-via"])
    if tv not in TIERS_VIA_ENUM:
        sys.stderr.write(f"read-test-config: tiers-via {tv!r} not in {sorted(TIERS_VIA_ENUM)}\n")
        sys.exit(2)
    fm["tiers-via"] = tv

# Optional object: opt-in-commands (closed cost-class vocabulary).
COST_ENUM = {"live", "costly"}
oic = fm.get("opt-in-commands")
if oic is not None:
    if not isinstance(oic, dict):
        sys.stderr.write("read-test-config: opt-in-commands must be an object with sub-keys\n")
        sys.exit(2)
    bad = set(oic.keys()) - COST_ENUM
    if bad:
        sys.stderr.write(
            f"read-test-config: opt-in-commands keys {sorted(bad)} not in {sorted(COST_ENUM)}\n"
        )
        sys.exit(2)

# Print key=value. default-command first; optional fields only when present;
# opt-in-commands flattened via dot notation.
ORDER = ["default-command", "runner", "layout", "tiers-via", "opt-in-commands"]
for k in ORDER:
    if k not in fm:
        continue
    v = fm[k]
    if isinstance(v, dict):
        for sk in opt_in_order:
            sv = v[sk]
            print(f"{k}.{sk}={unquote(sv)}")
    else:
        print(f"{k}={unquote(v)}")
PY
