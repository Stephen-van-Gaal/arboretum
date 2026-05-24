#!/usr/bin/env bash
# owner: workflow-unification
# read-s2-frontmatter.sh — Read & validate the S2 input frontmatter on
# a design spec (per docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md D3 + D5).
# Prints key=value lines on success (exit 0); exits 2 on any missing
# required field or invalid enum (whole-schema strict gate per D5).
#
# Required fields:
#   - related-issue: <int>
#   - test-tiers: <object with sub-keys (unit, contract, integration)>
#   - implementation-mode: direct | executing-plans | subagent-driven-development
#   - triage: agent-target | everything-else
#   - plan: <path> | null
set -euo pipefail
[ "$#" -eq 1 ] || { echo "Usage: $0 <design-spec-file>" >&2; exit 1; }
[ -f "$1" ] || { echo "design spec not found: $1" >&2; exit 1; }

python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

m = re.match(r"^---\n(.*?\n)---\n", text, re.DOTALL)
if not m:
    sys.stderr.write("read-s2-frontmatter: no frontmatter found (file must start with --- block)\n")
    sys.exit(2)
fm = m.group(1)

# Minimalist YAML parse — top-level `key: value` and one level of
# `key:` then indented sub-keys. Avoids pulling in PyYAML.
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

fm_parsed = parse(fm)

REQUIRED = ["related-issue", "test-tiers", "implementation-mode", "triage", "plan"]
MODE_ENUM = {"direct", "executing-plans", "subagent-driven-development"}
TRIAGE_ENUM = {"agent-target", "everything-else"}

missing = [f for f in REQUIRED if f not in fm_parsed]
if missing:
    sys.stderr.write(
        f"read-s2-frontmatter: missing required S2 field(s): {', '.join(missing)}\n"
    )
    sys.exit(2)

# Per-field type/enum validation. The reader treats this as part of
# the whole-schema strict gate from D5 — partial-schema compliance is
# still drift. Specifically:
#   - test-tiers MUST be an object with at least one of unit/contract/
#     integration sub-keys (silent acceptance of a scalar would let
#     Branch 2 dispatch treat tiers as absent — see PR #321 review).
#   - related-issue MUST be a positive integer (downstream gh issue
#     calls assume an int).
#   - plan MUST be `null` or a non-empty relative path (absolute paths
#     could escape the project dir; empty string is meaningless).

mode = fm_parsed["implementation-mode"]
if mode not in MODE_ENUM:
    sys.stderr.write(
        f"read-s2-frontmatter: implementation-mode {mode!r} not in {sorted(MODE_ENUM)}\n"
    )
    sys.exit(2)

triage = fm_parsed["triage"]
if triage not in TRIAGE_ENUM:
    sys.stderr.write(
        f"read-s2-frontmatter: triage {triage!r} not in {sorted(TRIAGE_ENUM)}\n"
    )
    sys.exit(2)

tiers = fm_parsed["test-tiers"]
TIER_KEYS = {"unit", "contract", "integration"}
if not isinstance(tiers, dict):
    sys.stderr.write(
        f"read-s2-frontmatter: test-tiers must be an object with sub-keys, got scalar {tiers!r}\n"
    )
    sys.exit(2)
present_tiers = TIER_KEYS & set(tiers.keys())
if not present_tiers:
    sys.stderr.write(
        f"read-s2-frontmatter: test-tiers must include at least one of {sorted(TIER_KEYS)}; got {sorted(tiers.keys())}\n"
    )
    sys.exit(2)

related = fm_parsed["related-issue"]
if not (isinstance(related, str) and related.isdigit() and int(related) > 0):
    sys.stderr.write(
        f"read-s2-frontmatter: related-issue must be a positive integer, got {related!r}\n"
    )
    sys.exit(2)

plan = fm_parsed["plan"]
if plan != "null":
    # Strip surrounding quotes that YAML accepts ('path' or "path").
    plan_stripped = plan.strip()
    if (plan_stripped.startswith("'") and plan_stripped.endswith("'")) or \
       (plan_stripped.startswith('"') and plan_stripped.endswith('"')):
        plan_stripped = plan_stripped[1:-1]
    if not plan_stripped:
        sys.stderr.write(
            "read-s2-frontmatter: plan must be `null` or a non-empty relative path; got empty string\n"
        )
        sys.exit(2)
    if plan_stripped.startswith("/"):
        sys.stderr.write(
            f"read-s2-frontmatter: plan must be a relative path, got absolute {plan_stripped!r}\n"
        )
        sys.exit(2)
    # Normalize the stored value to the unquoted form so the printed
    # plan=... line is what downstream callers expect.
    fm_parsed["plan"] = plan_stripped

# Print key=value. test-tiers is an object — flatten via dot notation.
for k in REQUIRED:
    v = fm_parsed[k]
    if isinstance(v, dict):
        for sk, sv in v.items():
            print(f"{k}.{sk}={sv}")
    else:
        print(f"{k}={v}")
PY
