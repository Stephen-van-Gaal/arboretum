#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: serial
#
# _smoke-test-contracts.sh — Validate the structural shape of every
# docs/contracts/*.contract.md file against the module-contract template.
#
# Asserts presence of:
#   - YAML frontmatter (file starts with `---` AND has a matching
#     closing `---` before any body content)
#   - Seven required frontmatter keys (seam, version, producer-type,
#     consumer-type, consumes, produces, related-designs)
#   - producer-type / consumer-type values are non-empty AND in the
#     closed enum (skill | script | hook | plugin | sub-agent | cross-repo)
#   - Five required body sections (## Producer, ## Consumer,
#     ## Protocol shape, ## Test surface, ## Versioning)
#   - Three required sub-headings (### Inputs, ### Outputs,
#     ### Invariants) appear within the `## Protocol shape` section
#     (not anywhere else in the file)
#   - At least one Test-surface bullet matching `- **<ID>:` within the
#     `## Test surface` section (not anywhere else in the file)
#
# Does NOT validate the test-surface assertion content — WS4's
# contract test framework owns that. This smoke test is the
# pre-WS4 shape-only check.
#
# Exit codes:
#   0 — all contracts under docs/contracts/ pass
#   1 — at least one contract violated a structural check (the
#       offending file + assertion is printed to stderr before exit)
#   2 — invocation problem (docs/contracts/ missing, etc.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$ROOT/docs/contracts"

if [ ! -d "$CONTRACTS_DIR" ]; then
  echo "ERROR: contracts directory not found at $CONTRACTS_DIR" >&2
  exit 2
fi

FAILED=0
COUNT=0
ENUM_VALUES="skill script hook plugin sub-agent cross-repo"

fail() {
  echo "FAIL: $1 — $2" >&2
  FAILED=1
}

# Check whether a value is in the closed consumer-type enum.
in_enum() {
  local val="$1"
  local v
  for v in $ENUM_VALUES; do
    [ "$val" = "$v" ] && return 0
  done
  return 1
}

# Extract the body content of a `## <section>` block — everything
# from the `## <section>` line (exclusive) up to (but not including)
# the next top-level `## ` heading or end of file. Prints to stdout.
extract_section() {
  local file="$1"
  local section="$2"
  awk -v target="$section" '
    BEGIN { in_sec = 0 }
    # New ## heading: if it matches our target, start capturing; if it
    # is any other ## heading and we were capturing, stop.
    /^## / {
      if ($0 == target) { in_sec = 1; next }
      if (in_sec)       { exit }
      next
    }
    in_sec { print }
  ' "$file"
}

# Iterate every .contract.md file under docs/contracts/.
shopt -s nullglob
for f in "$CONTRACTS_DIR"/*.contract.md; do
  COUNT=$((COUNT + 1))
  rel="${f#$ROOT/}"

  # Frontmatter present? (file starts with `---`)
  first_line="$(head -n 1 "$f")"
  if [ "$first_line" != "---" ]; then
    fail "$rel" "missing YAML frontmatter (file does not start with '---')"
    continue
  fi

  # Frontmatter terminated? (a second `---` line must appear before EOF).
  # Count `---` lines that are the entire content of the line.
  fm_delim_count="$(grep -cxF -- '---' "$f" || true)"
  if [ "$fm_delim_count" -lt 2 ]; then
    fail "$rel" "YAML frontmatter is not terminated (no closing '---' delimiter)"
    continue
  fi

  # Extract frontmatter block (between first two --- lines).
  fm="$(awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print} c==2{exit}' "$f")"

  # Seven required frontmatter keys.
  for key in seam version producer-type consumer-type consumes produces related-designs; do
    # Match `<key>:` at start of a line (allows scalar or block scalar value).
    if ! printf '%s\n' "$fm" | grep -qE "^${key}:"; then
      fail "$rel" "missing required frontmatter key '${key}'"
    fi
  done

  # producer-type / consumer-type enum check.
  # Non-empty value is required AND it must be in the closed enum.
  for typekey in producer-type consumer-type; do
    val="$(printf '%s\n' "$fm" | grep -E "^${typekey}:" | head -n 1 | sed -E "s/^${typekey}:[[:space:]]*//" | tr -d '[:space:]')"
    if [ -z "$val" ]; then
      fail "$rel" "${typekey}: value is empty (must be in closed enum)"
    elif ! in_enum "$val"; then
      fail "$rel" "${typekey}: '${val}' not in closed enum {${ENUM_VALUES// /, }}"
    fi
  done

  # Five required body sections (exact-line match at top level).
  for section in "## Producer" "## Consumer" "## Protocol shape" "## Test surface" "## Versioning"; do
    if ! grep -qxF "$section" "$f"; then
      fail "$rel" "missing required section header '${section}'"
    fi
  done

  # Three required sub-headings — must appear INSIDE the `## Protocol shape` section.
  protocol_body="$(extract_section "$f" "## Protocol shape")"
  if [ -z "$protocol_body" ]; then
    # Already reported above as a missing top-level section; skip
    # sub-heading checks rather than double-fail.
    :
  else
    for sub in "### Inputs" "### Outputs" "### Invariants"; do
      if ! printf '%s\n' "$protocol_body" | grep -qxF "$sub"; then
        fail "$rel" "missing sub-heading '${sub}' inside ## Protocol shape"
      fi
    done
  fi

  # At least one Test-surface bullet — must appear INSIDE the `## Test surface` section.
  test_body="$(extract_section "$f" "## Test surface")"
  if [ -z "$test_body" ]; then
    : # already reported above
  else
    if ! printf '%s\n' "$test_body" | grep -qE '^- \*\*[A-Za-z0-9-]+:'; then
      fail "$rel" "no '- **<ID>:' bullets inside ## Test surface"
    fi
  fi
done

if [ "$COUNT" -eq 0 ]; then
  echo "ERROR: no .contract.md files found under $CONTRACTS_DIR" >&2
  exit 2
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

echo "OK: $COUNT contract(s) validated"
