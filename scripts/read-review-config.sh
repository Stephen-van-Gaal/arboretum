#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# read-review-config.sh — Print the normalized review: config from .arboretum.yml.
#
# Output: `key=value` lines on stdout, one per field:
#   default_request_policy=<always|never|complexity-gated>
#   re_review_condition=<never|unresolved-only|substantive-only|always>
#   ai_reviewer.<name>.<request|re_request|cadence>=<value>
#   human_reviewers=<comma-separated logins or empty>
#
# Graceful absence: no review: block → print the two policy defaults and a
#   single `warn:` line to stderr, exit 0.
# Invalid enum value → exit 1 naming the offending key.
# Missing .arboretum.yml → exit 1.
#
# Uses scripts/lib/yaml-lite.sh so it runs from a bare checkout without
# PyYAML/yq. The ai_reviewers sequence-of-maps is emitted by yaml-lite as
# `review.ai_reviewers[N].<field>=...`; this script re-keys those by name.
set -uo pipefail

CONFIG=".arboretum.yml"
if [ ! -f "$CONFIG" ]; then
  echo "read-review-config.sh: $CONFIG not found in $(pwd)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_LITE="$SCRIPT_DIR/lib/yaml-lite.sh"
[ -f "$YAML_LITE" ] || {
  echo "read-review-config.sh: yaml-lite helper not found at $YAML_LITE" >&2
  exit 1
}

if ! PARSED=$(bash "$YAML_LITE" file "$CONFIG" 2>&1); then
  echo "read-review-config.sh: invalid YAML-lite in $CONFIG" >&2
  printf '%s\n' "$PARSED" >&2
  exit 1
fi

REVIEW_PARSED="$PARSED" python3 - <<'PY'
import os
import re
import sys

data = {}
for line in os.environ.get("REVIEW_PARSED", "").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        data[k] = v

POLICY_DEF = "complexity-gated"
RR_DEF = "substantive-only"
POLICY_ENUM = {"always", "never", "complexity-gated"}
RR_ENUM = {"never", "unresolved-only", "substantive-only", "always"}
REQ_ENUM = {"ready-for-review", "comment", "api-request", "add-reviewer"}
CAD_ENUM = {"auto", "auto-flaky", "comment-trigger", "reset-on-push"}

review_keys = [k for k in data if k == "review" or k.startswith("review.")]
if not review_keys:
    print(f"default_request_policy={POLICY_DEF}")
    print(f"re_review_condition={RR_DEF}")
    sys.stderr.write(
        "warn: no review: block in .arboretum.yml; using policy defaults "
        "(no reviewers will be requested)\n"
    )
    sys.exit(0)

errors = []
policy = data.get("review.default_request_policy", POLICY_DEF)
if policy not in POLICY_ENUM:
    errors.append(f"default_request_policy: invalid value {policy!r}")
rr = data.get("review.re_review_condition", RR_DEF)
if rr not in RR_ENUM:
    errors.append(f"re_review_condition: invalid value {rr!r}")

# Regroup ai_reviewers[N].<field> by list index, then emit by name.
idx_fields = {}
for k, v in data.items():
    m = re.match(r"review\.ai_reviewers\[(\d+)\]\.(\w+)$", k)
    if m:
        idx_fields.setdefault(int(m.group(1)), {})[m.group(2)] = v

reviewers = []
for i in sorted(idx_fields):
    fields = idx_fields[i]
    name = fields.get("name")
    if not name:
        continue
    for field in ("request", "re_request"):
        if field in fields and fields[field] not in REQ_ENUM:
            errors.append(f"ai_reviewer.{name}.{field}: invalid value {fields[field]!r}")
    if "cadence" in fields and fields["cadence"] not in CAD_ENUM:
        errors.append(f"ai_reviewer.{name}.cadence: invalid value {fields['cadence']!r}")
    reviewers.append((name, fields))

if errors:
    for e in errors:
        sys.stderr.write(f"read-review-config.sh: {e}\n")
    sys.exit(1)

out = [f"default_request_policy={policy}", f"re_review_condition={rr}"]
for name, fields in reviewers:
    for field in ("request", "re_request", "cadence"):
        if field in fields:
            out.append(f"ai_reviewer.{name}.{field}={fields[field]}")

hlogins = []
for k, v in data.items():
    m = re.match(r"review\.human_reviewers\[(\d+)\]\.login$", k)
    if m:
        hlogins.append(v)
out.append("human_reviewers=" + ",".join(hlogins))

print("\n".join(out))
PY
