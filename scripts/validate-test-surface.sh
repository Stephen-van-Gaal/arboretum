#!/usr/bin/env bash
# owner: pipeline-contracts-template
# validate-test-surface.sh — S3-6 enforcement.
#
# Usage: validate-test-surface.sh <design-spec-path> <changed-test-files-list-file>
#
# Asserts: the design spec's `test-surface-changes:` block (or
# `## Test surface changes` body section) lists every entry in the
# changed-files list, OR the spec's test-tiers declare every tier
# as `n/a — <reason>` AND the changed-files list is empty.

set -uo pipefail

[ "$#" -eq 2 ] || { echo "usage: validate-test-surface.sh <spec> <changed-files-list>" >&2; exit 2; }
SPEC="$1"
LIST="$2"
[ -f "$SPEC" ] || { echo "S3-6: spec not found: $SPEC" >&2; exit 2; }
[ -f "$LIST" ] || { echo "S3-6: changed-files list not found: $LIST" >&2; exit 2; }

ISSUES_FILE=$(mktemp)
block=$(mktemp)
trap 'rm -f "$ISSUES_FILE" "$block"' EXIT

# Has the test-surface block?
HAS_BLOCK=0
if grep -qE '^test-surface-changes:|^## Test surface changes' "$SPEC"; then
  HAS_BLOCK=1
fi

# Extract ONLY the test-tiers block first, then check tier values within it.
# (Plan v2 scanned the whole spec, so `unit: yes` in unrelated prose would
# falsely satisfy. Plan v3 retains the explicit-value rule: `yes` or
# `n/a — <reason>`; missing/malformed fails.)
tiers_block=$(awk '
  /^test-tiers:/                           { in_block=1; print; next }
  in_block && /^[a-zA-Z][a-zA-Z0-9_-]*:/   { in_block=0 }
  in_block && /^---$/                       { in_block=0 }
  in_block                                  { print }
' "$SPEC")

ALL_TIERS_NA=1
for tier in unit contract integration; do
  val=$(echo "$tiers_block" | grep -E "^[[:space:]]+${tier}:" | head -1 | sed -E "s/^[[:space:]]+${tier}:[[:space:]]*//")
  # Normalize: strip surrounding YAML quote chars so `unit: "yes"` and
  # `unit: 'yes'` are equivalent to `unit: yes`. validate-design-spec.sh
  # (via PyYAML) treats them all as the same semantic value; this parser
  # must agree or specs valid in one tool would be malformed in the other.
  val_norm=${val#\"}; val_norm=${val_norm%\"}
  val_norm=${val_norm#\'}; val_norm=${val_norm%\'}
  if [ -z "$val_norm" ]; then
    echo "test-tier $tier missing from test-tiers block" >> "$ISSUES_FILE"
    ALL_TIERS_NA=0
  elif [ "$val_norm" = "yes" ]; then
    ALL_TIERS_NA=0
  elif echo "$val_norm" | grep -qE "^n/a — .+"; then
    : # valid: n/a with a reason
  else
    echo "test-tier $tier malformed: '$val' (expected 'yes' or 'n/a — <reason>')" >> "$ISSUES_FILE"
    ALL_TIERS_NA=0
  fi
done

# Is the changed-files list empty?
LIST_EMPTY=1
[ -s "$LIST" ] && LIST_EMPTY=0

if [ "$HAS_BLOCK" -eq 1 ]; then
  # Extract ONLY the test-surface-changes section. Terminate frontmatter
  # extraction on the closing `---` delimiter so the body doesn't bleed
  # into the matched region.
  awk '
    /^test-surface-changes:/                    { in_fm=1; print; next }
    /^## Test surface changes/                  { in_body=1; print; next }
    in_fm  && /^---$/                           { in_fm=0; next }
    in_fm  && /^[a-zA-Z][a-zA-Z0-9_-]*:/        { in_fm=0 }
    in_body && /^## /                           { in_body=0 }
    in_fm || in_body                            { print }
  ' "$SPEC" > "$block"

  # Tokenize the block precisely — python3 strips YAML list prefixes
  # (`- `, `-`), surrounding quotes (`"` or `'`), and trailing
  # punctuation, then compares each changed-file entry to the set of
  # tokens exactly. This replaces the prior regex-token grep which had
  # two false-positive/false-negative classes Codex round 2 flagged:
  # (a) regex metachars in filenames (`.` in `foo-test.sh`) treated as
  #     wildcards → false positives on tokens differing by one char;
  # (b) boundary char class missing quotes → false negatives on the
  #     YAML-quoted form `- "foo-test.sh"`.
  if ! python3 - "$block" "$LIST" "$ISSUES_FILE" <<'PY'; then
import re
import sys

block_path, list_path, issues_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(block_path) as f:
    block_lines = f.read().splitlines()

# Extract one filename token per block line. The S3 contract requires
# entries to be "named with a reason" (test-surface-discipline post-
# condition), so reason-bearing forms must parse correctly:
#   - tests/foo.sh
#   - tests/foo.sh — reason text on same line
#   - "tests/foo.sh" — reason
#   - 'tests/foo.sh', reason
#   - tests/foo.sh  # inline comment-style reason
#   added:
#     - tests/foo.sh — added test for the new edge case
# Strip YAML list prefix, optional surrounding quotes around the
# filename, then capture the bare filename token. Whatever follows
# (em-dash + reason, comma + reason, comment-style reason) is the
# "reason on the same line" — parsed but ignored for set membership.
listed = set()
# `- ` list prefix; optional opening quote (captured for matching
# close); filename token (no whitespace, no quote, no comma); optional
# closing quote; optional trailing reason starting with whitespace,
# comma, em-dash, or `#`.
token_re = re.compile(r'^\s*-\s*(["\']?)([^"\'\s,]+)\1\s*([,#—-].*)?$')
for line in block_lines:
    m = token_re.match(line)
    if m:
        listed.add(m.group(2))

with open(list_path) as f:
    changed = [ln.strip() for ln in f.read().splitlines() if ln.strip()]

issues = []
for c in changed:
    if c not in listed:
        issues.append(f"test file {c} changed but not listed in test-surface-changes block")

with open(issues_path, "a") as out:
    for issue in issues:
        out.write(issue + "\n")
PY
    # Python tokenizer failed (missing interpreter, runtime exception,
    # etc.). Without `set -e`, this script would otherwise continue
    # silently to exit 0, masking the failure. Surface explicitly.
    echo "S3-6: validate-test-surface tokenizer failed (python3 error); refusing to declare spec compliant" >> "$ISSUES_FILE"
  fi
elif [ "$ALL_TIERS_NA" -eq 1 ] && [ "$LIST_EMPTY" -eq 1 ]; then
  : # all-tiers-N/A (explicitly) + no changes — valid
else
  echo "spec lacks test-surface-changes block and (test-tiers not all explicit N/A OR changed-files list not empty)" >> "$ISSUES_FILE"
fi

if [ -s "$ISSUES_FILE" ]; then
  count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
  echo "S3-6: $count issue(s) in $SPEC" >&2
  while IFS= read -r line; do echo "  - $line" >&2; done < "$ISSUES_FILE"
  exit 1
fi
exit 0
