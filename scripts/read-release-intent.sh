#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Parse the Release Intent section from a PR body or GitHub event JSON.

set -euo pipefail

usage() {
  echo "usage: read-release-intent.sh (--body-file <path> | --github-event <path>)" >&2
}

MODE=""
INPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -z "$MODE" ] || { echo "read-release-intent: choose exactly one input mode" >&2; exit 2; }
      MODE="body"
      INPUT="$2"
      shift 2
      ;;
    --github-event)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ -z "$MODE" ] || { echo "read-release-intent: choose exactly one input mode" >&2; exit 2; }
      MODE="github-event"
      INPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "read-release-intent: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$MODE" ] || { usage; exit 2; }
[ -f "$INPUT" ] || { echo "read-release-intent: file not found: $INPUT" >&2; exit 2; }

python3 - "$MODE" "$INPUT" <<'PY'
import json
import re
import sys

mode, path = sys.argv[1], sys.argv[2]


def fail(message, code=1):
    print(f"read-release-intent: {message}", file=sys.stderr)
    sys.exit(code)


try:
    if mode == "body":
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
        source = "body"
    elif mode == "github-event":
        with open(path, encoding="utf-8") as fh:
            event = json.load(fh)
        body = event.get("pull_request", {}).get("body")
        if body is None:
            fail("github event missing pull_request.body")
        source = "github-event"
    else:
        fail(f"unsupported mode: {mode}", 2)
except OSError as exc:
    fail(str(exc), 2)
except json.JSONDecodeError as exc:
    fail(f"invalid github event JSON: {exc}", 1)

lines = body.splitlines()
section = []
in_section = False
for raw in lines:
    line = raw.rstrip()
    if re.match(r"^##[ \t]+Release Intent[ \t]*$", line):
        if in_section:
            fail("duplicate Release Intent section")
        in_section = True
        continue
    if in_section and re.match(r"^##[ \t]+", line):
        break
    if in_section:
        section.append(line)

if not in_section:
    fail("release intent section missing")

values = {}
for line in section:
    stripped = line.strip()
    if not stripped or stripped.startswith("<!--"):
        continue
    if ":" not in stripped:
        fail(f"malformed release intent line: {stripped}")
    key, value = stripped.split(":", 1)
    key = key.strip()
    value = value.strip()
    if key in values:
        fail(f"duplicate {key}")
    values[key] = value

allowed_keys = {"release-impact", "release-state"}
unknown = sorted(set(values) - allowed_keys)
if unknown:
    fail(f"unknown release intent key: {unknown[0]}")

for required in ("release-impact", "release-state"):
    if required not in values:
        fail(f"{required} missing")

impact = values["release-impact"]
state = values["release-state"]

if impact not in {"none", "patch", "minor", "major"}:
    fail(f"invalid release-impact: {impact}")
if state not in {"not-needed", "pending", "materialized"}:
    fail(f"invalid release-state: {state}")
if impact == "none" and state != "not-needed":
    fail("release-impact none requires release-state not-needed")
if impact in {"patch", "minor", "major"} and state == "not-needed":
    fail("release-impact patch|minor|major cannot use release-state not-needed")

print(f"release-impact={impact}")
print(f"release-state={state}")
print(f"source={source}")
PY
