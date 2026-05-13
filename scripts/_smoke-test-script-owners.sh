#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-script-owners.sh — Assert every shipped framework script
# declares a valid spec owner on line 2.
#
# Walks scripts/ (excluding _archived/ and _fixtures/) and .claude/hooks/.
# For each *.sh file, asserts:
#   1. Line 2 is exactly `# owner: <name>` where <name> matches
#      [a-z][a-z0-9-]+ (kebab-case spec name).
#   2. `docs/specs/<name>.spec.md` exists in the host project.
#
# Catches the failure mode from issue #9: shipped scripts without
# owner headers cause consumer projects to fail "Unowned source
# files" governance checks on adoption.
#
# Usage: bash scripts/_smoke-test-script-owners.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$PROJECT_ROOT/docs/specs"

[ -d "$SPECS_DIR" ] || { echo "FAIL: docs/specs/ not found at $SPECS_DIR" >&2; exit 1; }

# Build the search list: all *.sh under scripts/ (excluding _archived/
# and _fixtures/) and .claude/hooks/.
scripts_to_check=()
while IFS= read -r f; do
  scripts_to_check+=("$f")
done < <(
  find "$PROJECT_ROOT/scripts" \
       -type d \( -name _archived -o -name _fixtures \) -prune -o \
       -type f -name '*.sh' -print
  if [ -d "$PROJECT_ROOT/.claude/hooks" ]; then
    find "$PROJECT_ROOT/.claude/hooks" -type f -name '*.sh' -print
  fi
)

fail_count=0
fail() {
  echo "FAIL: $1" >&2
  ((fail_count++)) || true
}

# Holding the regex in a variable and referencing it unquoted is the
# bash-recommended way to keep regex semantics under [[ =~ ]] — inline
# patterns with backslash-escaped spaces (`\ `) work on some bash
# builds but are engine-dependent and can be parsed as literal '(' on
# others, leaving BASH_REMATCH unset.
owner_re='^# owner: ([a-z][a-z0-9-]+)$'

for f in "${scripts_to_check[@]}"; do
  rel="${f#$PROJECT_ROOT/}"

  # Line 2 must match `# owner: <name>`.
  line2=$(sed -n '2p' "$f")
  if ! [[ "$line2" =~ $owner_re ]]; then
    fail "$rel: line 2 is not '# owner: <spec-name>' (got: $line2)"
    continue
  fi
  owner_name="${BASH_REMATCH[1]}"

  # Resolve to a spec file.
  if [ ! -f "$SPECS_DIR/$owner_name.spec.md" ]; then
    fail "$rel: declared owner '$owner_name' has no spec at docs/specs/$owner_name.spec.md"
  fi
done

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $fail_count script(s) failed owner-header validation" >&2
  exit 1
fi

echo "PASS: ${#scripts_to_check[@]} scripts validated (all have # owner: headers resolving to specs)"
