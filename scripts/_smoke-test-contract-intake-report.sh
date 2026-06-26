#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
# Smoke test for docs/contracts/intake-report.contract.md.
# Asserts the WS7 Stage 0 intake metadata contract is machine-readable
# and carries the required v1 fields.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$ROOT/docs/contracts/intake-report.contract.md"

fail() {
  echo "FAIL intake-report: $1" >&2
  exit 1
}

[ -f "$CONTRACT" ] || fail "contract file missing"

grep -q 'schema_version' "$CONTRACT" || fail "schema_version field missing"
grep -q 'report_type' "$CONTRACT" || fail "report_type field missing"
grep -q 'redaction_reviewed' "$CONTRACT" || fail "redaction_reviewed field missing"

python3 - "$CONTRACT" <<'PY'
import json
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
marker = "<!-- arboretum-intake-report"
marker_lines = [
    index for index, line in enumerate(lines)
    if line.strip() == marker
]
if len(marker_lines) != 1:
    print(f"expected exactly one metadata block, found {len(marker_lines)}", file=sys.stderr)
    sys.exit(1)
start = sum(len(line) for line in lines[:marker_lines[0] + 1])
end = text.find("-->", start)
if end == -1:
    print("metadata block closing marker not found", file=sys.stderr)
    sys.exit(1)
data = json.loads(text[start:end])
required = {
    "schema_version",
    "report_type",
    "generated_at",
    "source",
    "arboretum",
    "runtime",
    "surface",
    "failure",
    "privacy",
}
missing = sorted(required - set(data))
if missing:
    print("missing required top-level fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if data["schema_version"] != "1.0":
    print("schema_version must be 1.0", file=sys.stderr)
    sys.exit(1)
if data["report_type"] not in {"problem", "enhancement"}:
    print("report_type enum invalid", file=sys.stderr)
    sys.exit(1)
if data["source"].get("channel") not in {"report-skill", "manual-form"}:
    print("source.channel enum invalid", file=sys.stderr)
    sys.exit(1)
if data["failure"].get("reproducibility") not in {
    "reproducible",
    "intermittent",
    "unknown",
    "not-applicable",
}:
    print("failure.reproducibility enum invalid", file=sys.stderr)
    sys.exit(1)
if not data["failure"].get("error_signature"):
    print("failure.error_signature missing", file=sys.stderr)
    sys.exit(1)
if data["privacy"].get("redaction_reviewed") is not True:
    print("privacy.redaction_reviewed must be true in skill-filed reports", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS intake-report contract"
