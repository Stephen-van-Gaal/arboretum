#!/usr/bin/env bash
# owner: extract-shared-component
# Catalog schema validator. Survey phase runs this as a self-check before
# presenting candidates; the contract test exercises it with good/bad fixtures.
#
# Usage: validate-catalog.sh <catalog.md>
# Exit 0 if every "### <id>" candidate section carries all required fields and a
# valid worth_extracting enum; non-zero (with diagnostics on stderr) otherwise.
set -euo pipefail

CATALOG="${1:?usage: validate-catalog.sh <catalog.md>}"
[ -f "$CATALOG" ] || { echo "catalog not found: $CATALOG" >&2; exit 2; }

REQUIRED=(tier clone_type pattern occurrences distinct_files languages rough_contract home worth_extracting notes)
# Portable ERE boundary: `\b` is a GNU grep extension (unreliable under BSD grep).
# An enum value is the bare word or the word followed by whitespace (e.g. "yes — why").
ENUM_RE='^(yes|no|needs-decision)([[:space:]]|$)'

rc=0
in_candidate=0
id=""
declare -A seen

flush() {  # validate the candidate just ended
  [ "$in_candidate" -eq 1 ] || return 0
  local field
  for field in "${REQUIRED[@]}"; do
    if [ -z "${seen[$field]:-}" ]; then
      echo "candidate '$id': missing required field '$field'" >&2
      rc=1
    fi
  done
  if [ -n "${seen[worth_extracting]:-}" ] && ! grep -qE "$ENUM_RE" <<<"${seen[worth_extracting]}"; then
    echo "candidate '$id': worth_extracting must be yes|no|needs-decision, got: ${seen[worth_extracting]}" >&2
    rc=1
  fi
}

while IFS= read -r line; do
  if [[ "$line" =~ ^###[[:space:]]+(.*) ]]; then
    flush
    in_candidate=1; id="${BASH_REMATCH[1]}"; unset seen; declare -A seen
    continue
  fi
  # match "- **<field>:** <value>"
  if [[ "$line" =~ ^-[[:space:]]+\*\*([a-z_]+):\*\*[[:space:]]*(.*) ]]; then
    seen["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  fi
done < "$CATALOG"
flush

if [ "$in_candidate" -eq 0 ]; then
  echo "no candidate sections (### <id>) found in $CATALOG" >&2
  rc=1
fi

exit "$rc"
