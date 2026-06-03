#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-script-owners.sh — Assert every shipped framework source
# file declares a valid spec owner.
#
# Walks scripts/ (excluding _archived/ and _fixtures/), .claude/hooks/,
# bin/, and skills/*/SKILL.md.
# For each *.sh file and each bin/* executable, asserts:
#   1. Line 1 is exactly `#!/usr/bin/env bash`.
#   2. Line 2 is exactly `# owner: <name>` where <name> matches
#      [a-z][a-z0-9-]+ (kebab-case spec name).
#   3. `docs/specs/<name>.spec.md` exists in the host project.
# For each skills/*/SKILL.md, asserts the same against the YAML
# frontmatter `owner:` key instead of a line-2 comment.
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

is_plugin_root() {
  [ -d "$PROJECT_ROOT/skills" ] \
    && [ -d "$PROJECT_ROOT/hooks" ] \
    && [ -d "$PROJECT_ROOT/docs/contracts" ] \
    && [ -d "$PROJECT_ROOT/tests/contracts" ] \
    && [ -d "$PROJECT_ROOT/scripts/_fixtures/roadmap" ] \
    && [ -f "$PROJECT_ROOT/.github/ISSUE_TEMPLATE/agent-ready.md" ]
}

if ! is_plugin_root; then
  echo "SKIP: script owner validation requires the Arboretum plugin-root layout"
  exit 0
fi

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

check_shell_owner_header_order() {
  f="$1"
  SHELL_OWNER_NAME=
  SHELL_HEADER_REASON=

  line1=$(sed -n '1p' "$f")
  if [ "$line1" != "#!/usr/bin/env bash" ]; then
    SHELL_HEADER_REASON="line 1 is not '#!/usr/bin/env bash' (got: $line1)"
    return 1
  fi

  line2=$(sed -n '2p' "$f")
  if ! [[ "$line2" =~ $owner_re ]]; then
    SHELL_HEADER_REASON="line 2 is not '# owner: <spec-name>' (got: $line2)"
    return 1
  fi
  SHELL_OWNER_NAME="${BASH_REMATCH[1]}"
  return 0
}

assert_shell_owner_header_order() {
  f="$1"
  rel="$2"

  if ! check_shell_owner_header_order "$f"; then
    fail "$rel: $SHELL_HEADER_REASON"
    return 1
  fi
  return 0
}

# Holding the regex in a variable and referencing it unquoted is the
# bash-recommended way to keep regex semantics under [[ =~ ]] — inline
# patterns with backslash-escaped spaces (`\ `) work on some bash
# builds but are engine-dependent and can be parsed as literal '(' on
# others, leaving BASH_REMATCH unset.
owner_re='^# owner: ([a-z][a-z0-9-]+)$'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
printf '#!/usr/bin/env bash\n# owner: project-infrastructure\n' > "$fixture_dir/good.sh"
assert_shell_owner_header_order "$fixture_dir/good.sh" "fixture/good.sh"
printf '# owner: project-infrastructure\n#!/usr/bin/env bash\n' > "$fixture_dir/owner-before-shebang.sh"
if check_shell_owner_header_order "$fixture_dir/owner-before-shebang.sh"; then
  fail "fixture/owner-before-shebang.sh: accepted owner-before-shebang header order"
elif [ "$SHELL_HEADER_REASON" != "line 1 is not '#!/usr/bin/env bash' (got: # owner: project-infrastructure)" ]; then
  fail "fixture/owner-before-shebang.sh: rejected for unexpected reason ($SHELL_HEADER_REASON)"
fi

for f in "${scripts_to_check[@]}"; do
  rel="${f#"$PROJECT_ROOT"/}"

  if ! assert_shell_owner_header_order "$f" "$rel"; then
    continue
  fi
  owner_name="$SHELL_OWNER_NAME"

  # Resolve to a spec file.
  if [ ! -f "$SPECS_DIR/$owner_name.spec.md" ]; then
    fail "$rel: declared owner '$owner_name' has no spec at docs/specs/$owner_name.spec.md"
  fi
done

# bin/* executables — shell shebang line 1 and line-2 `# owner:` header
# (same convention as .sh).
if [ -d "$PROJECT_ROOT/bin" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#"$PROJECT_ROOT"/}"
    if ! assert_shell_owner_header_order "$f" "$rel"; then
      continue
    fi
    if [ ! -f "$SPECS_DIR/$SHELL_OWNER_NAME.spec.md" ]; then
      fail "$rel: declared owner '$SHELL_OWNER_NAME' has no spec at docs/specs/$SHELL_OWNER_NAME.spec.md"
    fi
  done < <(
    find "$PROJECT_ROOT/bin" \
      -type d -name __pycache__ -prune -o \
      -type f ! -name '*.pyc' -print
  )
fi

# skills/*/SKILL.md — YAML frontmatter `owner:` key.
skill_owner_re='^owner:[[:space:]]*([a-z][a-z0-9-]+)[[:space:]]*$'
if [ -d "$PROJECT_ROOT/skills" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#"$PROJECT_ROOT"/}"
    owner_line=$(awk '/^---[[:space:]]*$/{n++; next} n>=2{exit} n==1 && /^owner:/{print; exit}' "$f")
    if ! [[ "$owner_line" =~ $skill_owner_re ]]; then
      fail "$rel: no 'owner: <spec-name>' key in YAML frontmatter (got: ${owner_line:-<none>})"
      continue
    fi
    if [ ! -f "$SPECS_DIR/${BASH_REMATCH[1]}.spec.md" ]; then
      fail "$rel: declared owner '${BASH_REMATCH[1]}' has no spec at docs/specs/${BASH_REMATCH[1]}.spec.md"
    fi
  done < <(find "$PROJECT_ROOT/skills" -type f -name 'SKILL.md' -print)
fi

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $fail_count script(s) failed owner-header validation" >&2
  exit 1
fi

echo "PASS: all source files validated (.sh, bin/, SKILL.md owner markers resolve to specs)"
