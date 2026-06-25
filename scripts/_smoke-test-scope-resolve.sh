#!/usr/bin/env bash
# owner: framework-scope-marker
# scope: plugin-only
# _smoke-test-scope-resolve.sh — unit tests for the scope-resolve helper.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/scope-resolve.sh"
FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }

# .sh marker present
printf '#!/usr/bin/env bash\n# owner: x\n# scope: plugin-only\necho hi\n' > "$FIX/a.sh"
[ "$(file_scope "$FIX/a.sh")" = plugin-only ] && pass "sh plugin-only" || bad "sh plugin-only"

# .sh marker absent -> none
printf '#!/usr/bin/env bash\n# owner: x\necho hi\n' > "$FIX/b.sh"
[ "$(file_scope "$FIX/b.sh")" = none ] && pass "sh absent->none" || bad "sh absent->none ($(file_scope "$FIX/b.sh"))"

# .sh consumer
printf '#!/usr/bin/env bash\n# owner: x\n# scope: consumer\n' > "$FIX/c.sh"
[ "$(file_scope "$FIX/c.sh")" = consumer ] && pass "sh consumer" || bad "sh consumer"

# SKILL.md frontmatter
mkdir -p "$FIX/sk"
printf -- '---\nname: s\nowner: y\nscope: plugin-only\n---\n# Skill\n' > "$FIX/sk/SKILL.md"
[ "$(file_scope "$FIX/sk/SKILL.md")" = plugin-only ] && pass "skill plugin-only" || bad "skill plugin-only ($(file_scope "$FIX/sk/SKILL.md"))"

# SKILL.md no scope key -> none
mkdir -p "$FIX/sk2"; printf -- '---\nname: s\nowner: y\n---\n' > "$FIX/sk2/SKILL.md"
[ "$(file_scope "$FIX/sk2/SKILL.md")" = none ] && pass "skill absent->none" || bad "skill absent->none"

# unreadable/absent file under a set -e + pipefail caller must resolve to none,
# not inherit sed/awk's non-zero status and abort (file_scope never-fails contract)
( set -eo pipefail; v="$(file_scope "$FIX/does-not-exist.sh")"; [ "$v" = none ] ) \
  && pass "set -e unreadable->none" || bad "set -e unreadable->none"

# predicate
governed_by_framework_in_consumer_root "$FIX/a.sh" && pass "governed plugin-only=0" || bad "governed plugin-only=0"
governed_by_framework_in_consumer_root "$FIX/b.sh" && bad "governed none must be 1" || pass "governed none=1"
governed_by_framework_in_consumer_root "$FIX/c.sh" && bad "governed consumer must be 1" || pass "governed consumer=1"

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
