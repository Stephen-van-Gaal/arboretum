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

python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

m = re.match(r"^---\n(.*?\n)---\n", text, re.DOTALL)
if not m:
    sys.stderr.write("read-test-config: no frontmatter found (file must start with --- block)\n")
    sys.exit(2)

# Minimalist YAML parse — top-level `key: value` and one level of indented
# sub-keys. Mirrors scripts/read-s2-frontmatter.sh; avoids a PyYAML dependency.
def parse(fm_text):
    out = {}
    cur_key = None
    cur_sub = {}
    for line in fm_text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("  ") and cur_key is not None:
            sub = line.strip()
            if ":" in sub:
                k, v = sub.split(":", 1)
                cur_sub[k.strip()] = v.strip()
            continue
        if cur_key is not None and cur_sub:
            out[cur_key] = cur_sub
            cur_sub = {}
            cur_key = None
        if ":" in line:
            k, v = line.split(":", 1)
            k, v = k.strip(), v.strip()
            if v:
                out[k] = v
                cur_key = None
            else:
                cur_key = k
                cur_sub = {}
    if cur_key is not None and cur_sub:
        out[cur_key] = cur_sub
    return out

def unquote(s):
    s = s.strip()
    if (s.startswith("'") and s.endswith("'")) or (s.startswith('"') and s.endswith('"')):
        return s[1:-1]
    return s

fm = parse(m.group(1))

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
        for sk, sv in v.items():
            print(f"{k}.{sk}={unquote(sv)}")
    else:
        print(f"{k}={unquote(v)}")
PY
