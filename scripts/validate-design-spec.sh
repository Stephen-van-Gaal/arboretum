#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# validate-design-spec.sh - S2 contract enforcement.
#
# Validates a design spec's frontmatter against the S2 contract
# (`docs/contracts/s2-design-to-build.contract.md`):
#
#   related-issue       - positive integer
#   triage              - closed enum: agent-target | everything-else
#   implementation-mode - closed enum: direct | executing-plans | subagent-driven-development
#   plan                - relative path string OR the literal `null`
#   test-tiers          - object with keys unit, contract, integration;
#                         each value is `yes` or a reason-bearing `n/a ...`
#
# Output format:
#   Summary line: `S2-DRIFT: <count> issues in <path>`
#   One indented line per issue: `  - <field>: <reason>`
#
# Exit codes:
#   0 - spec is valid
#   1 - one or more contract violations (issues printed to stderr)
#   2 - invocation problem (file missing, unreadable, etc.)

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || {
  echo "validate-design-spec.sh: yaml-lite helper not found at $YAML_LITE" >&2
  exit 2
}
ISSUES_FILE=$(mktemp)
PARSED_FILE=$(mktemp)
PARSER_ERR=$(mktemp)
trap 'rm -f "$ISSUES_FILE" "$PARSED_FILE" "$PARSER_ERR"' EXIT

if bash "$YAML_LITE" frontmatter "$SPEC" >"$PARSED_FILE" 2>"$PARSER_ERR"; then
  python3 - "$SPEC" "$ISSUES_FILE" "$PARSED_FILE" <<'PY'
import os
import sys

spec_path = sys.argv[1]
issues_path = sys.argv[2]
parsed_path = sys.argv[3]

fm = {}
tiers = {}
with open(parsed_path, encoding="utf-8") as parsed:
    for raw in parsed:
        line = raw.rstrip("\n")
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("test-tiers."):
            tiers[key.split(".", 1)[1]] = value
        else:
            fm[key] = value
if tiers:
    fm["test-tiers"] = tiers

issues = []

# related-issue: positive integer
ri = fm.get("related-issue")
if ri is None:
    issues.append("related-issue: missing")
elif not (str(ri).isdigit() and int(str(ri)) > 0):
    issues.append(f"related-issue: not a positive integer (got {ri!r})")

# kind: optional closed enum; absent ⇒ buildable. A shaping doc is a
# non-buildable design artifact (epic/shaping) — it needs only the identity
# field (related-issue, checked above) and skips the build-targeted schema so
# it does not have to masquerade as a /build input. (#692)
KIND_ENUM = {"buildable", "shaping"}
# A mapping-valued kind (e.g. `kind: {value: shaping}`) flattens to `kind.<sub>`
# lines with no literal `kind=` key, which would read as absent ⇒ buildable —
# a fail-open for a malformed shaping marker with complete build fields. Reject
# it as invalid (fail-safe). (#692, Codex review)
if any(k.startswith("kind.") for k in fm) and "kind" not in fm:
    issues.append("kind: must be a scalar enum value (buildable|shaping), not a mapping")
    kind = "__invalid__"
else:
    kind = fm.get("kind", "buildable")
    if kind not in KIND_ENUM:
        issues.append(f"kind: not in {sorted(KIND_ENUM)} (got {kind!r})")
if kind != "buildable":
    # Non-buildable (or invalid kind): stop after the identity check, plus the
    # shaping-only substrate-survey requirement (S2-9, #934). The build-only
    # fields are neither required nor validated here; /build refuses the doc at
    # consume time via read-s2-frontmatter.sh (exit 3).
    if kind == "shaping":
        # S2-9: a shaping doc must carry a non-empty `## Substrate Survey`
        # section — the mechanical floor under the agent's substrate survey.
        # Presence-only: the heading must exist with at least one non-blank,
        # non-heading content line under it. The table/verdict are not parsed.
        with open(spec_path, encoding="utf-8") as body:
            lines = body.read().splitlines()
        # Fence-aware scan: a `## Substrate Survey` line inside a fenced code
        # block is a quoted example, not the real section — skip it. A fence is
        # closed only by a run of the same marker family (``` vs ~~~) at least
        # as long as the opener (CommonMark), so a ~~~ line inside a ``` fence
        # (or a shorter ``` run inside a longer one) does not end it.
        def _fence_run(s):
            # Return the (char, length) of a leading fence run, or (None, 0).
            if s[:3] in ("```", "~~~"):
                ch = s[0]
                return ch, len(s) - len(s.lstrip(ch))
            return None, 0

        fence_marker = ""  # the opening run, e.g. "```" or "~~~~"; "" when open
        heading_idx = None
        for i, line in enumerate(lines):
            stripped = line.strip()
            ch, n = _fence_run(stripped)
            if not fence_marker:
                if ch is not None:
                    fence_marker = ch * n  # open a fence
                    continue
                if stripped == "## Substrate Survey":
                    heading_idx = i
                    break
            else:
                # Inside a fence: close only on a same-family run >= opener that
                # is *only* fence chars (a closing fence carries no info string).
                if (
                    ch == fence_marker[0]
                    and n >= len(fence_marker)
                    and stripped == ch * n
                ):
                    fence_marker = ""
                continue
        if heading_idx is None:
            issues.append(
                "Substrate Survey: required section missing (kind: shaping)"
            )
        else:
            has_content = False
            for line in lines[heading_idx + 1:]:
                stripped = line.strip()
                # A fenced code block under the heading is real content.
                if stripped.startswith("```") or stripped.startswith("~~~"):
                    has_content = True
                    break
                # Only a new top-level (H1/H2) heading ends the section. Deeper
                # subheadings (### …) and non-heading '#' lines (#1 …) are
                # section content, not a boundary.
                if (
                    stripped.startswith("# ")
                    or stripped.startswith("## ")
                    or stripped in ("#", "##")
                ):
                    break
                if stripped:
                    has_content = True
                    break
            if not has_content:
                issues.append("Substrate Survey: section is empty")
    with open(issues_path, "w", encoding="utf-8") as out:
        for issue in issues:
            out.write(issue + "\n")
    sys.exit(1 if issues else 0)

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

# plan: string or null literal
missing_sentinel = "__missing__"
plan = fm.get("plan", missing_sentinel)
if plan == missing_sentinel:
    issues.append("plan: missing (use 'null' for pure-TDD mode)")
elif plan == "":
    issues.append("plan: must be string path or null (got empty string)")

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
        normalized = str(v).strip()
        normalized_lower = normalized.lower()
        if normalized_lower in {"yes", "true"}:
            continue
        if (
            normalized_lower.startswith("n/a - ")
            or normalized_lower.startswith("n/a -- ")
            or normalized_lower.startswith("n/a — ")
        ):
            continue
        issues.append(f"test-tiers.{tier}: must be 'yes' or 'n/a — <reason>' (got {v!r})")

# Cross-field invariant: plan: null forbids implementation-mode: executing-plans.
if plan == "null" and im == "executing-plans":
    issues.append(
        "plan: null is incompatible with implementation-mode: executing-plans "
        "(executing-plans requires a plan file)"
    )

# Cross-field invariant: when plan is a path, it must be relative and exist.
if isinstance(plan, str) and plan not in {missing_sentinel, "null", ""}:
    if plan.startswith("/"):
        issues.append(f"plan: must be a relative path, got absolute {plan!r}")
    spec_dir = os.path.dirname(os.path.abspath(spec_path))
    root = spec_dir
    while root != "/":
        if any(os.path.exists(os.path.join(root, marker)) for marker in (".git", "CLAUDE.md")):
            break
        root = os.path.dirname(root)
    plan_resolved = os.path.join(root, plan) if not os.path.isabs(plan) else plan
    if not os.path.exists(plan_resolved):
        issues.append(f"plan: file not found at {plan} (resolved: {plan_resolved})")

with open(issues_path, "w", encoding="utf-8") as out:
    for issue in issues:
        out.write(issue + "\n")

sys.exit(1 if issues else 0)
PY
  rc=$?
else
  {
    echo "frontmatter: invalid YAML-lite"
    sed 's/^/frontmatter parser: /' "$PARSER_ERR"
  } >"$ISSUES_FILE"
  rc=1
fi

if [ "$rc" -ne 0 ] && [ -s "$ISSUES_FILE" ]; then
  count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
  echo "S2-DRIFT: $count issue(s) in $SPEC" >&2
  while IFS= read -r line; do
    echo "  - $line" >&2
  done < "$ISSUES_FILE"
fi

exit "$rc"
