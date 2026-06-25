#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# validate-review-dispositions.sh <pr>
#
# Validate .arboretum/land/<pr>/dispositions.json against the collected
# comments.json ledger before /land or review-closeout performs provider writes.
set -uo pipefail

PR="${1:-}"
[ -n "$PR" ] || { echo "usage: validate-review-dispositions.sh <pr>" >&2; exit 2; }
case "$PR" in
  *[!0-9]*|"") echo "validate-review-dispositions.sh: PR must be a positive integer (got '$PR')" >&2; exit 2 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
LAND_DIR="$ROOT/.arboretum/land/$PR"
COMMENTS="$LAND_DIR/comments.json"
DISPOSITIONS="$LAND_DIR/dispositions.json"

[ -f "$COMMENTS" ] || { echo "validate-review-dispositions.sh: missing $COMMENTS" >&2; exit 2; }
[ -f "$DISPOSITIONS" ] || { echo "validate-review-dispositions.sh: missing $DISPOSITIONS" >&2; exit 2; }

python3 - "$PR" "$COMMENTS" "$DISPOSITIONS" <<'PY'
import json
import sys

pr_raw, comments_path, dispositions_path = sys.argv[1:4]
pr = int(pr_raw)

DISPOSITIONS = {
    "fix",
    "already-addressed",
    "defer",
    "wont-fix",
    "judgment-call",
    "duplicate",
    "outdated",
    "informational",
}
SEVERITIES = {"substantive", "nit", "none"}
ACTIONS = {"fix-in-batch", "no-code-change", "ask-human", "manual-follow-up"}


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        print(f"validate-review-dispositions.sh: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)


def non_empty_string(value):
    return isinstance(value, str) and bool(value.strip())


comments = load_json(comments_path)
ledger = load_json(dispositions_path)
errors = []

if not isinstance(comments, list):
    errors.append("comments.json must be an array")
    known_ids = set()
else:
    known_ids = {item.get("id") for item in comments if isinstance(item, dict)}

if not isinstance(ledger, dict):
    errors.append("dispositions.json must be an object")
    ledger = {}

if ledger.get("schema") != "review-dispositions.v1":
    errors.append("schema must be review-dispositions.v1")

if ledger.get("pr") != pr:
    errors.append(f"pr must be {pr}")

items = ledger.get("items")
if not isinstance(items, list):
    errors.append("items must be an array")
    items = []

seen = set()
for index, item in enumerate(items):
    where = f"items[{index}]"
    if not isinstance(item, dict):
        errors.append(f"{where} must be an object")
        continue

    cid = item.get("comment_id")
    if cid not in known_ids:
        errors.append(f"{where}.comment_id {cid!r} is not present in comments.json")
    if cid in seen:
        errors.append(f"{where}.comment_id {cid!r} is duplicated")
    seen.add(cid)

    disposition = item.get("disposition")
    severity = item.get("severity")
    action = item.get("action")
    if disposition not in DISPOSITIONS:
        errors.append(f"{where}.disposition {disposition!r} is not allowed")
    if severity not in SEVERITIES:
        errors.append(f"{where}.severity {severity!r} is not allowed")
    if action not in ACTIONS:
        errors.append(f"{where}.action {action!r} is not allowed")
    if not isinstance(item.get("resolve_after_closeout"), bool):
        errors.append(f"{where}.resolve_after_closeout must be boolean")
    if not isinstance(item.get("reply"), str):
        errors.append(f"{where}.reply must be a string")
    if not non_empty_string(item.get("reason")):
        errors.append(f"{where}.reason must be a non-empty string")

    if disposition == "fix" and not non_empty_string(item.get("cluster")):
        errors.append(f"{where}.cluster is required for fix dispositions")
    if item.get("resolve_after_closeout") is True and not non_empty_string(item.get("reply")):
        errors.append(f"{where}.reply is required when resolve_after_closeout is true")
    if action == "ask-human" and item.get("resolve_after_closeout") is True:
        errors.append(f"{where}.action ask-human cannot set resolve_after_closeout=true")

if errors:
    for error in errors:
        print(f"DISPOSITION-DRIFT: {error}", file=sys.stderr)
    sys.exit(1)

print(f"OK: review-dispositions ledger valid for PR {pr}")
PY
