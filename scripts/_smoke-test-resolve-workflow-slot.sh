#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-resolve-workflow-slot.sh - Verify workflow skill slot resolution.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/resolve-workflow-slot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

write_skill() {
  local path="$1"
  local name="$2"
  local slot="${3:-ship-tail.reflect}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<MD
---
name: $name
owner: workflow-unification
description: Fixture skill for workflow slot tests.
implements-slots:
  - $slot
---

# $name
MD
}

write_incompatible_skill() {
  local path="$1"
  local name="$2"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<MD
---
name: $name
owner: workflow-unification
description: Fixture skill without slot metadata.
---

# $name
MD
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo/skills/reflect" "$repo/.claude/skills"
  write_skill "$repo/skills/reflect/SKILL.md" "reflect"
}

run_resolver() {
  local repo="$1"
  shift
  local out="$TMP/out"
  local err="$TMP/err"
  set +e
  bash "$RESOLVER" "$@" --repo-root "$repo" >"$out" 2>"$err"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$TMP/rc"
}

assert_success() {
  local label="$1"
  local rc
  rc="$(cat "$TMP/rc")"
  [ "$rc" = "0" ] || fail "$label should pass" "$(cat "$TMP/err")"
}

assert_failure() {
  local label="$1"
  local rc
  rc="$(cat "$TMP/rc")"
  [ "$rc" != "0" ] || fail "$label should fail" "$(cat "$TMP/out")"
}

assert_out() {
  local expected="$1"
  grep -qxF "$expected" "$TMP/out" || fail "missing output: $expected" "$(cat "$TMP/out")"
}

assert_err_contains() {
  local expected="$1"
  grep -qF "$expected" "$TMP/err" || fail "missing diagnostic: $expected" "$(cat "$TMP/err")"
}

repo_default="$TMP/default"
make_repo "$repo_default"
run_resolver "$repo_default" ship-tail.reflect
assert_success "default slot"
assert_out "slot=ship-tail.reflect"
assert_out "target=/reflect"
assert_out "source=default"
assert_out "status=resolved"
assert_out "skill_path=skills/reflect/SKILL.md"
ok "default ship-tail.reflect resolves to /reflect"

if grep -q '^dogfood: true$' "$REPO_ROOT/.arboretum.yml" 2>/dev/null; then
  run_resolver "$REPO_ROOT" ship-tail.reflect
  assert_success "arboretum-dev dogfood slot"
  assert_out "slot=ship-tail.reflect"
  assert_out "target=/reflect-dev"
  assert_out "source=.arboretum.yml"
  assert_out "status=resolved"
  assert_out "skill_path=.claude/skills/reflect-dev/SKILL.md"
  ok "arboretum-dev dogfood slot resolves to /reflect-dev"
fi

repo_dev="$TMP/dev-override"
make_repo "$repo_dev"
write_skill "$repo_dev/.claude/skills/reflect-dev/SKILL.md" "reflect-dev"
cat >"$repo_dev/.arboretum.yml" <<'YAML'
workflow:
  skill_slots:
    ship-tail.reflect: /reflect-dev
YAML
run_resolver "$repo_dev" ship-tail.reflect
assert_success "configured dev override"
assert_out "slot=ship-tail.reflect"
assert_out "target=/reflect-dev"
assert_out "source=.arboretum.yml"
assert_out "status=resolved"
assert_out "skill_path=.claude/skills/reflect-dev/SKILL.md"
ok "configured dev-only slot target resolves"

repo_bad_syntax="$TMP/bad-syntax"
make_repo "$repo_bad_syntax"
cat >"$repo_bad_syntax/.arboretum.yml" <<'YAML'
workflow:
  skill_slots:
    ship-tail.reflect: reflect-dev
YAML
run_resolver "$repo_bad_syntax" ship-tail.reflect
assert_failure "bad target syntax"
assert_err_contains "target must be slash-style"
ok "configured target without leading slash fails"

repo_empty_target="$TMP/empty-target"
make_repo "$repo_empty_target"
cat >"$repo_empty_target/.arboretum.yml" <<'YAML'
workflow:
  skill_slots:
    ship-tail.reflect:
YAML
run_resolver "$repo_empty_target" ship-tail.reflect
assert_failure "empty target"
assert_err_contains "target must be slash-style"
ok "configured empty target fails"

repo_missing="$TMP/missing-target"
make_repo "$repo_missing"
cat >"$repo_missing/.arboretum.yml" <<'YAML'
workflow:
  skill_slots:
    ship-tail.reflect: /reflect-dev
YAML
run_resolver "$repo_missing" ship-tail.reflect
assert_failure "missing target"
assert_err_contains "skill target not found"
ok "configured missing target fails"

repo_incompatible="$TMP/incompatible-target"
make_repo "$repo_incompatible"
write_incompatible_skill "$repo_incompatible/.claude/skills/reflect-dev/SKILL.md" "reflect-dev"
cat >"$repo_incompatible/.arboretum.yml" <<'YAML'
workflow:
  skill_slots:
    ship-tail.reflect: /reflect-dev
YAML
run_resolver "$repo_incompatible" ship-tail.reflect
assert_failure "incompatible target"
assert_err_contains "missing implements-slots"
ok "configured incompatible target fails"

repo_unknown="$TMP/unknown-slot"
make_repo "$repo_unknown"
run_resolver "$repo_unknown" design.orchestrate
assert_failure "unknown slot"
assert_err_contains "unknown workflow skill slot"
ok "unknown slot fails"

echo "resolve-workflow-slot smoke: ALL PASS"
