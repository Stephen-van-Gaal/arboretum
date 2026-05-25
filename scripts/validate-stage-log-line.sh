#!/usr/bin/env bash
# owner: pipeline-contracts-template
# validate-stage-log-line.sh — S9-5 contract enforcement.
#
# Validates a comment block emitted by scripts/log-stage.sh against
# the S9 contract's comment-marker conformance assertion (S9-5).
#
# Expected shape (per S9 contract `### Outputs` and log-stage.sh line 116):
#   <!-- pipeline-state:log -->
#   - <ISO-8601-UTC-zulu timestamp> — <stage> <action>[, <k>: <v>]...
#
# Where:
#   - timestamp matches YYYY-MM-DDTHH:MM:SSZ (literal Z, no offset)
#   - separator between timestamp and stage is " — " (em dash)
#   - stage is a token starting with `/` (e.g. /build, /design)
#   - action is one of the seven-entry vocabulary (CWD-2):
#       entered | exited | skipped | re-entered | summary | repair | dispatched
#   - kv pairs use `: ` (colon-space) rendering form, comma-space separated
#
# Output format mirrors the other validators:
#   S9-DRIFT: <N> issue(s) in <file>
#     - <assertion-id>: <reason>
#
# Exit codes:
#   0 — line conforms
#   1 — contract violation(s)
#   2 — invocation problem

set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: validate-stage-log-line.sh <comment-file>" >&2
  exit 2
fi

FILE="$1"
if [ ! -f "$FILE" ]; then
  echo "validate-stage-log-line.sh: file not found: $FILE" >&2
  exit 2
fi

ISSUES_FILE=$(mktemp)
trap 'rm -f "$ISSUES_FILE"' EXIT

python3 - "$FILE" "$ISSUES_FILE" <<'PY'
import re
import sys

src_path = sys.argv[1]
issues_path = sys.argv[2]

ACTIONS = {"entered", "exited", "skipped", "re-entered", "summary", "repair", "dispatched"}
MARKER = "<!-- pipeline-state:log -->"

with open(src_path) as f:
    lines = f.read().splitlines()

issues = []

# Line 1: marker
if not lines or lines[0] != MARKER:
    got = lines[0] if lines else "(empty)"
    issues.append(f"S9-5: missing marker on line 1 (expected '{MARKER}', got '{got}')")

# Line 2: data line
if len(lines) < 2:
    issues.append("S9-5: missing data line (line 2)")
else:
    data = lines[1]
    if not data.startswith("- "):
        issues.append(f"S9-5: line 2 must begin with '- ' (got: '{data[:40]}...')")
    else:
        payload = data[2:]  # strip "- "
        # Split on " — " (em dash with spaces) to separate timestamp from rest
        if " — " not in payload:
            issues.append("S9-5: line 2 missing ' — ' (em-dash) separator between timestamp and stage")
        else:
            ts, rest = payload.split(" — ", 1)
            # Timestamp: ISO-8601 UTC zulu
            if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", ts):
                issues.append(f"S9-5: timestamp '{ts}' is not ISO-8601-UTC-zulu (expected YYYY-MM-DDTHH:MM:SSZ)")

            # Rest is "STAGE ACTION[, KEY: VALUE]*"
            # Split into head (before first ", ") and kv tail
            head, _, kv_tail = rest.partition(", ")
            head_tokens = head.split()
            if len(head_tokens) < 2:
                issues.append(f"S9-5: header section before kv pairs must be '<stage> <action>' (got: '{head}')")
            else:
                stage = head_tokens[0]
                action = head_tokens[1]
                if not re.match(r"^/[a-z][a-z0-9-]*$", stage):
                    issues.append(f"S9-5: stage '{stage}' must start with '/' and be lowercase-kebab")
                if action not in ACTIONS:
                    issues.append(f"S9-2: action '{action}' not in seven-entry vocabulary ({sorted(ACTIONS)})")

            # S9-7 quoting: detect unquoted values containing the structural ', '
            # Walk kv pairs (split on top-level `, ` not inside double quotes).
            # Top-level split = scan and track quote state.
            if kv_tail:
                pairs = []
                cur = []
                in_q = False
                i = 0
                while i < len(kv_tail):
                    c = kv_tail[i]
                    if c == '\\' and i + 1 < len(kv_tail) and in_q:
                        cur.append(c)
                        cur.append(kv_tail[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        in_q = not in_q
                        cur.append(c)
                    elif c == ',' and i + 1 < len(kv_tail) and kv_tail[i + 1] == ' ' and not in_q:
                        pairs.append("".join(cur))
                        cur = []
                        i += 2
                        continue
                    else:
                        cur.append(c)
                    i += 1
                if cur:
                    pairs.append("".join(cur))

                # Unterminated quoted-value: scanner ended with in_q=True,
                # meaning the line carries an open double-quote with no
                # matching close. S9-7's escape contract requires balanced
                # quote state — reject explicitly rather than letting the
                # malformed pair fall through to the kv-shape check.
                if in_q:
                    issues.append("S9-7: unterminated double-quoted value (line ends inside a quoted region)")

                # Each pair must look like "key: value" with value either
                # bare (no `, `) or wrapped in double quotes. A pair lacking
                # ": " is most commonly evidence of an unquoted-comma in a
                # prior value that caused the structural-comma tokeniser to
                # mis-split — surface as S9-7 quoting violation.
                for pair in pairs:
                    if ": " not in pair:
                        issues.append(f"S9-7: malformed kv pair '{pair}' — likely an unquoted ', ' in a prior value (must be double-quoted)")
                        continue
                    k, v = pair.split(": ", 1)
                    if not re.match(r"^[a-z][a-z0-9_-]*$", k.strip()):
                        issues.append(f"S9-5: key '{k}' must be lowercase-kebab/snake")
                        continue
                    # A value containing ', ' (the structural delimiter) at top
                    # level without surrounding double-quotes is an S9-7 violation.
                    # We already pre-tokenised on unquoted commas, so any pair with
                    # a `, ` at this point means the value contains it bare.
                    if ", " in v and not (v.startswith('"') and v.endswith('"')):
                        issues.append(f"S9-7: unquoted value with embedded ', ' delimiter (must be double-quoted) in pair '{pair}'")

with open(issues_path, "w") as out:
    for issue in issues:
        out.write(issue + "\n")

sys.exit(1 if issues else 0)
PY

rc=$?

if [ "$rc" -ne 0 ] && [ -s "$ISSUES_FILE" ]; then
  count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
  echo "S9-DRIFT: $count issue(s) in $FILE" >&2
  while IFS= read -r line; do
    echo "  - $line" >&2
  done < "$ISSUES_FILE"
fi

exit "$rc"
