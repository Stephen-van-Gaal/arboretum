#!/usr/bin/env bash
# owner: pipeline-contracts-template
# validate-design-spec.sh — S2 contract enforcement.
#
# Validates a design spec's frontmatter against the S2 contract
# (`docs/contracts/s2-design-to-build.contract.md`):
#
#   related-issue      — positive integer
#   triage             — closed enum: agent-target | everything-else
#   implementation-mode — closed enum: direct | executing-plans | subagent-driven-development
#   plan               — relative path string OR the literal `null`
#   test-tiers         — object with keys unit, contract, integration;
#                        each value is `yes` or a string starting `n/a — `
#
# Additional invariants:
#   - plan: null requires implementation-mode in {direct, subagent-driven-development}
#     (executing-plans requires a plan file)
#   - when plan: <path>, the file must exist at the path resolved
#     against the spec's repo root
#
# Output format (per WS4 design spec OQ1, picked here):
#   Summary line: `S2-DRIFT: <count> issues in <path>`
#   One indented line per issue: `  - <field>: <reason>`
#
# Exit codes:
#   0 — spec is valid
#   1 — one or more contract violations (issues printed to stderr)
#   2 — invocation problem (file missing, unreadable, etc.)

set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: validate-design-spec.sh <design-spec-path>" >&2
  exit 2
fi

SPEC="$1"
if [ ! -f "$SPEC" ]; then
  echo "validate-design-spec.sh: file not found: $SPEC" >&2
  exit 2
fi

# Use python3 + PyYAML to parse frontmatter — matches read-pipeline-flag.sh.
# Frontmatter is everything between the first two `---` lines.
ISSUES_FILE=$(mktemp)
trap 'rm -f "$ISSUES_FILE"' EXIT

python3 - "$SPEC" "$ISSUES_FILE" <<'PY'
import os
import re
import sys
import yaml

spec_path = sys.argv[1]
issues_path = sys.argv[2]

with open(spec_path) as f:
    content = f.read()

m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
if not m:
    with open(issues_path, "w") as out:
        out.write("frontmatter: missing or malformed (no leading --- block)\n")
    sys.exit(1)

try:
    fm = yaml.safe_load(m.group(1)) or {}
except yaml.YAMLError as e:
    with open(issues_path, "w") as out:
        out.write(f"frontmatter: invalid YAML: {e}\n")
    sys.exit(1)

issues = []

# related-issue: positive integer
ri = fm.get("related-issue")
if ri is None:
    issues.append("related-issue: missing")
elif not isinstance(ri, int) or ri <= 0:
    issues.append(f"related-issue: not a positive integer (got {ri!r})")

# triage: closed enum
TRIAGE_ENUM = {"agent-target", "everything-else"}
tr = fm.get("triage")
if tr is None:
    issues.append("triage: missing")
elif tr not in TRIAGE_ENUM:
    issues.append(f"triage: not in {sorted(TRIAGE_ENUM)} (got {tr!r})")

# implementation-mode: closed enum
IM_ENUM = {"direct", "executing-plans", "subagent-driven-development"}
im = fm.get("implementation-mode")
if im is None:
    issues.append("implementation-mode: missing")
elif im not in IM_ENUM:
    issues.append(f"implementation-mode: not in {sorted(IM_ENUM)} (got {im!r})")

# plan: string or None
plan = fm.get("plan", "__missing__")
if plan == "__missing__":
    issues.append("plan: missing (use 'null' for pure-TDD mode)")
elif plan is not None and not isinstance(plan, str):
    issues.append(f"plan: must be string path or null (got {type(plan).__name__})")

# test-tiers: object with three keys
TIERS_REQUIRED = ["unit", "contract", "integration"]
tt = fm.get("test-tiers")
if tt is None:
    issues.append("test-tiers: missing")
elif not isinstance(tt, dict):
    issues.append(f"test-tiers: must be a mapping (got {type(tt).__name__})")
else:
    for tier in TIERS_REQUIRED:
        v = tt.get(tier)
        if v is None:
            issues.append(f"test-tiers.{tier}: missing")
            continue
        # YAML 1.1 (PyYAML) parses unquoted `yes` → boolean True; accept both.
        if v is True or v == "yes":
            continue
        if isinstance(v, str) and v.startswith("n/a — "):
            continue
        issues.append(f"test-tiers.{tier}: must be 'yes' or 'n/a — <reason>' (got {v!r})")

# Cross-field invariant: plan: null forbids implementation-mode: executing-plans
if plan is None and im == "executing-plans":
    issues.append(
        "plan: null is incompatible with implementation-mode: executing-plans "
        "(executing-plans requires a plan file)"
    )

# Cross-field invariant: when plan is a path, it must be relative (per
# the S2 contract — absolute paths can escape the project dir) and the
# file must exist.
if isinstance(plan, str):
    if plan.startswith("/"):
        issues.append(f"plan: must be a relative path, got absolute {plan!r}")
    spec_dir = os.path.dirname(os.path.abspath(spec_path))
    # Walk up to find repo root (presence of .git or CLAUDE.md)
    root = spec_dir
    while root != "/":
        if any(os.path.exists(os.path.join(root, marker)) for marker in (".git", "CLAUDE.md")):
            break
        root = os.path.dirname(root)
    plan_resolved = os.path.join(root, plan) if not os.path.isabs(plan) else plan
    if not os.path.exists(plan_resolved):
        issues.append(f"plan: file not found at {plan} (resolved: {plan_resolved})")

with open(issues_path, "w") as out:
    for issue in issues:
        out.write(issue + "\n")

sys.exit(1 if issues else 0)
PY

rc=$?

if [ "$rc" -ne 0 ] && [ -s "$ISSUES_FILE" ]; then
  count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
  echo "S2-DRIFT: $count issue(s) in $SPEC" >&2
  while IFS= read -r line; do
    echo "  - $line" >&2
  done < "$ISSUES_FILE"
fi

exit "$rc"
