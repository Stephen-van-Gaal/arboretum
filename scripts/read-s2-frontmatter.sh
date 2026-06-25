#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || { echo "read-s2-frontmatter: yaml-lite helper not found at $YAML_LITE" >&2; exit 1; }

PARSED_FILE=$(mktemp)
PARSER_ERR=$(mktemp)
trap 'rm -f "$PARSED_FILE" "$PARSER_ERR"' EXIT

if ! bash "$YAML_LITE" frontmatter "$1" >"$PARSED_FILE" 2>"$PARSER_ERR"; then
  echo "read-s2-frontmatter: invalid or missing frontmatter" >&2
  sed 's/^/read-s2-frontmatter: /' "$PARSER_ERR" >&2
  exit 2
fi

python3 - "$1" "$PARSED_FILE" <<'PY'
import sys

parsed_path = sys.argv[2]

fm_parsed = {}
test_tiers = {}
test_tier_order = []

with open(parsed_path, encoding="utf-8") as parsed:
    for raw in parsed:
        line = raw.rstrip("\n")
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("test-tiers."):
            subkey = key.split(".", 1)[1]
            if subkey not in test_tiers:
                test_tier_order.append(subkey)
            test_tiers[subkey] = value
        elif key == "test-tiers":
            fm_parsed[key] = value
        elif key in {"related-issue", "implementation-mode", "triage", "plan", "kind"}:
            fm_parsed[key] = value
        elif key.startswith("kind."):
            # Mapping-valued kind (e.g. `kind: {value: shaping}`) flattens here
            # with no literal `kind=` key — record so we can reject it below.
            fm_parsed["__kind_mapping__"] = "1"

if test_tiers:
    fm_parsed["test-tiers"] = test_tiers

# kind: closed enum {buildable, shaping}; absent ⇒ buildable. Both checks run
# BEFORE the missing-field gate so the consumer gate is self-contained — it does
# not rely on validate-design-spec.sh having run first (#692).
#
# An out-of-enum kind is malformed drift: exit 2 (same class as a bad
# implementation-mode/triage enum) so /build surfaces the generic drift message.
# Without this, a doc with an invalid kind but otherwise-complete five fields
# would fall through to exit 0 and be treated as buildable.
KIND_ENUM = {"buildable", "shaping"}
if fm_parsed.get("__kind_mapping__") == "1" and "kind" not in fm_parsed:
    # Mapping-valued kind is malformed — reject as drift rather than letting it
    # read as absent ⇒ buildable (fail-open). (#692, Codex review)
    sys.stderr.write(
        f"read-s2-frontmatter: {sys.argv[1]} has invalid kind "
        "(mapping; expected a scalar buildable|shaping); fix in /design.\n"
    )
    sys.exit(2)
kind = fm_parsed.get("kind")
if kind is not None and kind not in KIND_ENUM:
    sys.stderr.write(
        f"read-s2-frontmatter: {sys.argv[1]} has invalid kind {kind!r} "
        f"(must be one of {sorted(KIND_ENUM)}); fix in /design.\n"
    )
    sys.exit(2)

# kind: shaping is a non-buildable design artifact (epic/shaping doc). Refuse
# cleanly with a DISTINCT exit code (3) so /build can surface a specific
# "non-buildable" message instead of a generic "missing required field(s)"
# error. Exit 2 stays reserved for real drift.
if kind == "shaping":
    sys.stderr.write(
        f"read-s2-frontmatter: {sys.argv[1]} is a non-buildable shaping document "
        "(kind: shaping); /build only runs buildable design specs — its children "
        "build individually.\n"
    )
    sys.exit(3)

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
        for sk in test_tier_order:
            sv = v[sk]
            print(f"{k}.{sk}={sv}")
    else:
        print(f"{k}={v}")
PY
