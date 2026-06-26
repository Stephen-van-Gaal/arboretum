#!/usr/bin/env bash
# owner: project-upgrade
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-session-start-staleness.sh — Verify the project-tree staleness
# signal in session-start.sh (issue #316).
#
# Covers:
#   1. install-manifest has OLDER framework_version than update-cache -> signal fires
#   2. install-manifest has SAME version as update-cache -> signal suppressed
#   3. install-manifest absent -> signal suppressed (arboretum-dev case)
#   4. install-manifest NEWER than update-cache -> signal suppressed (no false positive)
#   5. control chars in the version string are scrubbed before render (defense in depth)
#
# Each case builds an isolated fixture under a tempdir and runs
# `.claude/hooks/session-start.sh` against it via CLAUDE_PROJECT_DIR.
#
# Usage: bash scripts/_smoke-test-session-start-staleness.sh
# Exit 0 if all cases pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

# jq is required by the staleness block — skip gracefully if unavailable.
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available — staleness block requires jq; skipping smoke test"
  exit 0
fi

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; printf '%s\n' "$2" >&2; }
  exit 1
}

ok() { echo "PASS: $1"; }

# ── Helper: build a minimal fixture project ──────────────────────────

new_fixture() {
  local name="$1"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/docs/definitions" "$fix/docs/specs" "$fix/scripts" \
           "$fix/.claude/hooks" "$fix/.arboretum"
  echo "# fixture" > "$fix/docs/ARCHITECTURE.md"
  echo "# fixture" > "$fix/docs/REGISTER.md"
  echo "# fixture" > "$fix/contracts.yaml"
  cat > "$fix/.arboretum.yml" <<'EOF'
layer: 0
EOF
  cp "$HOOK" "$fix/.claude/hooks/session-start.sh"
  mkdir -p "$fix/scripts/lib"; cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"

  # Minimal git repo so hook's git calls don't error under set -e.
  git -C "$fix" init -q
  git -C "$fix" config user.email "fixture@example.com"
  git -C "$fix" config user.name "fixture"
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" -c commit.gpgsign=false -c gpg.program=true \
      commit -q --allow-empty -m "fixture seed" >/dev/null 2>&1 || true

  echo "$fix"
}

# Write update-cache.json so the hook's installed_version source is populated.
write_update_cache() {
  local fix="$1"
  local instv="$2"
  cat > "$fix/.arboretum/update-cache.json" <<EOF
{
  "fetched_at": "2026-01-01T00:00:00Z",
  "installed_version": "$instv",
  "latest_version": "$instv",
  "update_available": false,
  "error": null
}
EOF
}

# Write install-manifest.json with the given framework_version. jq encodes the
# value, so a raw control byte in $mfv becomes a valid JSON \uXXXX escape on disk
# (which the hook's own jq read decodes back to the raw byte — exactly the path
# the scrub must defend).
write_install_manifest() {
  local fix="$1"
  local mfv="$2"
  jq -n --arg fv "$mfv" \
    '{schema_version:1, framework_version:$fv, updated_at:"2026-01-01T00:00:00Z", files:{}}' \
    > "$fix/.arboretum/install-manifest.json"
}

run_hook() {
  local fix="$1"
  CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" 2>&1
}

# ── Case 1: manifest OLDER than installed → staleness signal fires ────

case1() {
  local fix; fix=$(new_fixture case1)
  write_update_cache "$fix" "0.18.6"
  write_install_manifest "$fix" "0.1.0"
  local out; out=$(run_hook "$fix")
  echo "$out" | grep -q '\[Arboretum\] Project tree is behind the installed plugin' \
    || fail "case1: staleness signal absent when manifest older than installed" "$out"
  echo "$out" | grep -q '0.1.0' \
    || fail "case1: manifest version not rendered" "$out"
  echo "$out" | grep -q '/upgrade' \
    || fail "case1: /upgrade hint absent" "$out"
  ok "case1: manifest older than installed → staleness signal fires"
}

# ── Case 2: manifest SAME as installed → signal suppressed ───────────

case2() {
  local fix; fix=$(new_fixture case2)
  write_update_cache "$fix" "0.18.6"
  write_install_manifest "$fix" "0.18.6"
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q '\[Arboretum\] Project tree is behind'; then
    fail "case2: staleness signal fired when versions are equal" "$out"
  fi
  ok "case2: manifest == installed → staleness signal suppressed"
}

# ── Case 3: install-manifest absent → signal suppressed ──────────────

case3() {
  local fix; fix=$(new_fixture case3)
  write_update_cache "$fix" "0.18.6"
  # No install-manifest.json written — simulates arboretum-dev itself.
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q '\[Arboretum\] Project tree is behind'; then
    fail "case3: staleness signal fired with no install-manifest" "$out"
  fi
  ok "case3: no install-manifest → staleness signal suppressed"
}

# ── Case 4: manifest NEWER than installed → signal suppressed (no false positive) ──

case4() {
  local fix; fix=$(new_fixture case4)
  write_update_cache "$fix" "0.18.6"
  write_install_manifest "$fix" "0.19.0"
  local out; out=$(run_hook "$fix")
  if echo "$out" | grep -q '\[Arboretum\] Project tree is behind'; then
    fail "case4: staleness signal fired when manifest is newer than installed (false positive on downgrade/manual edit)" "$out"
  fi
  ok "case4: manifest newer than installed → staleness signal suppressed"
}

# ── Case 5: control chars in version scrubbed before render (defense in depth) ──

case5() {
  local fix; fix=$(new_fixture case5)
  write_update_cache "$fix" "0.18.6"
  # Embed a raw ESC byte (printf '\033') in the framework_version. jq stores it as
  # a valid  escape on disk; the hook decodes it back to a raw ESC, which the
  # scrub MUST strip before the banner renders. No literal escape lives in source.
  local esc; esc=$(printf '\033')
  write_install_manifest "$fix" "0.1.0${esc}[31mEVIL"
  local out; out=$(run_hook "$fix")
  if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; then
    fail "case5: ESC control char rendered into banner (scrub failed)" "$out"
  fi
  ok "case5: control chars in version scrubbed before render"
}

# ── Case 6: newline in version does NOT inject a second banner line ──

case6() {
  local fix; fix=$(new_fixture case6)
  write_update_cache "$fix" "0.18.6"
  # Embed a newline + marker in framework_version. If the scrub fails to strip \n,
  # the banner will contain a line equal to "INJECTED" (a prompt-injection vector).
  # The widened tr -d '\000-\037\177-\237' must strip \n (octal \012) and \r (\015).
  local nl; nl=$(printf '\n')
  write_install_manifest "$fix" "0.1.0${nl}INJECTED"
  local out; out=$(run_hook "$fix")
  if printf '%s\n' "$out" | grep -qx 'INJECTED'; then
    fail "case6: newline in version injected extra banner line (scrub must strip \\n)" "$out"
  fi
  ok "case6: newline in version does not inject extra banner line"
}

# ── Run all cases ─────────────────────────────────────────────────────

case1
case2
case3
case4
case5
case6

echo
echo "All staleness smoke-test cases passed."
exit 0
