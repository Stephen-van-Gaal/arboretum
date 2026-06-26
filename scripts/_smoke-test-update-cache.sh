#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-update-cache.sh — Smoke tests for refresh-update-cache.sh.
#
# Tests:
#   T1: no plugin manifest → error=manifest-not-found
#   T2: manifest found, no gh → error=gh-unavailable, installed_version captured
#   T3: installed 0.2.2, latest v0.2.3 → update_available=true
#   T4: installed 0.2.3, latest v0.2.3 → update_available=false
#   T5: gh fails with "release not found" → error=no-release
#   T6: multiple installed versions → picks highest
#   T7: default discovery finds Codex plugin cache
#   T8: default discovery prefers Codex cache over a higher Claude install
#   T9: Claude sessions prefer Claude cache over a higher Codex install
#
# Usage: bash scripts/_smoke-test-update-cache.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-update-cache.sh"

[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -n "${2:-}" ] && { printf -- '----- detail -----\n%s\n' "$2" >&2; }
  exit 1
}

pass() { printf 'PASS: %s\n' "$1"; }

# Create a fake plugin manifest at a given version under a given cache root
make_manifest() {
  local cache_root="$1" version="$2"
  local dir="$cache_root/arboretum/arboretum/$version/.claude-plugin"
  mkdir -p "$dir"
  printf '{"name": "arboretum", "version": "%s"}\n' "$version" > "$dir/plugin.json"
}

# Read a top-level string field from a JSON cache file
cache_field() {
  python3 -c "
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  v = d.get(sys.argv[2])
  print('' if v is None else str(v))
except Exception:
  pass
" "$1" "$2"
}

# Build an isolated bin with symlinks to required utilities but no gh.
# This guarantees T2 works regardless of where the host gh is installed.
ISOLATED_BIN="$FIXTURE/isolated-bin"
mkdir -p "$ISOLATED_BIN"
for _cmd in bash find grep sed sort mktemp mkdir mv rm date head tail cat wc python3; do
  _loc=$(command -v "$_cmd" 2>/dev/null) && ln -sf "$_loc" "$ISOLATED_BIN/$_cmd" || true
done

# Fake gh template for T3-T6: assert it is not called with "latest" as a
# positional argument (which would query a tag named "latest" rather than
# the actual latest release).
make_fake_gh() {
  local bin="$1" tag="$2"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash
for arg; do [ "$arg" = "latest" ] && { echo "ERROR: called with positional \"latest\"" >&2; exit 2; }; done
echo "%s"
' "$tag" > "$bin/gh"
  chmod +x "$bin/gh"
}

# ── T1: no manifest → manifest-not-found ────────────────────────────

proj="$FIXTURE/t1"
mkdir -p "$proj"
ARBORETUM_PLUGIN_CACHE="$FIXTURE/empty" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T1" "cache file not written"
err=$(cache_field "$cache" error)
[ "$err" = "manifest-not-found" ] || fail "T1" "expected manifest-not-found, got: $err"
pass "T1: no manifest → manifest-not-found"

# ── T2: manifest found, no gh → gh-unavailable ──────────────────────
# Uses ISOLATED_BIN (no gh symlink) so the test is environment-independent.

proj="$FIXTURE/t2"
mkdir -p "$proj"
fake_plugins="$FIXTURE/plugins-t2"
make_manifest "$fake_plugins" "0.2.2"
ARBORETUM_PLUGIN_CACHE="$fake_plugins" \
  PATH="$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T2" "cache file not written"
err=$(cache_field "$cache" error)
iv=$(cache_field "$cache" installed_version)
[ "$err" = "gh-unavailable" ] || fail "T2" "expected gh-unavailable, got: $err"
[ "$iv" = "0.2.2" ]           || fail "T2" "expected installed_version=0.2.2, got: $iv"
pass "T2: no gh → gh-unavailable, installed_version captured"

# ── T3: 0.2.2 installed, v0.2.3 latest → update_available=true ──────

proj="$FIXTURE/t3"
mkdir -p "$proj"
fake_plugins="$FIXTURE/plugins-t3"
make_manifest "$fake_plugins" "0.2.2"
make_fake_gh "$FIXTURE/bin-t3" "v0.2.3"
ARBORETUM_PLUGIN_CACHE="$fake_plugins" \
  PATH="$FIXTURE/bin-t3:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T3" "cache file not written"
ua=$(cache_field "$cache" update_available)
lv=$(cache_field "$cache" latest_version)
[ "$ua" = "True" ]  || fail "T3" "expected update_available=True, got: $ua"
[ "$lv" = "0.2.3" ] || fail "T3" "expected latest_version=0.2.3, got: $lv"
pass "T3: 0.2.2 < 0.2.3 → update_available=true"

# ── T4: already on latest → update_available=false ──────────────────

proj="$FIXTURE/t4"
mkdir -p "$proj"
fake_plugins="$FIXTURE/plugins-t4"
make_manifest "$fake_plugins" "0.2.3"
make_fake_gh "$FIXTURE/bin-t4" "v0.2.3"
ARBORETUM_PLUGIN_CACHE="$fake_plugins" \
  PATH="$FIXTURE/bin-t4:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T4" "cache file not written"
ua=$(cache_field "$cache" update_available)
[ "$ua" = "False" ] || fail "T4" "expected update_available=False, got: $ua"
pass "T4: 0.2.3 == 0.2.3 → update_available=false"

# ── T5: gh says "release not found" → no-release ────────────────────
# T5 uses a hand-rolled gh stub (not make_fake_gh) because the error path
# exits 1 before printing a tag — a different code path than T3/T4/T6.

proj="$FIXTURE/t5"
mkdir -p "$proj"
fake_plugins="$FIXTURE/plugins-t5"
make_manifest "$fake_plugins" "0.2.2"
mkdir -p "$FIXTURE/bin-t5"
printf '#!/usr/bin/env bash\nfor arg; do [ "$arg" = "latest" ] && { echo "ERROR: called with positional \"latest\"" >&2; exit 2; }; done\necho "release not found" >&2\nexit 1\n' \
  > "$FIXTURE/bin-t5/gh"
chmod +x "$FIXTURE/bin-t5/gh"
ARBORETUM_PLUGIN_CACHE="$fake_plugins" \
  PATH="$FIXTURE/bin-t5:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T5" "cache file not written"
err=$(cache_field "$cache" error)
[ "$err" = "no-release" ] || fail "T5" "expected no-release, got: $err"
pass "T5: gh release not found → no-release"

# ── T6: multiple versions installed → picks highest ──────────────────

proj="$FIXTURE/t6"
mkdir -p "$proj"
fake_plugins="$FIXTURE/plugins-t6"
make_manifest "$fake_plugins" "0.2.1"
make_manifest "$fake_plugins" "0.2.2"
make_manifest "$fake_plugins" "0.1.9"
make_fake_gh "$FIXTURE/bin-t6" "v0.3.0"
ARBORETUM_PLUGIN_CACHE="$fake_plugins" \
  PATH="$FIXTURE/bin-t6:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T6" "cache file not written"
iv=$(cache_field "$cache" installed_version)
ua=$(cache_field "$cache" update_available)
[ "$iv" = "0.2.2" ] || fail "T6" "expected highest version 0.2.2, got: $iv"
[ "$ua" = "True" ]  || fail "T6" "expected update_available=True, got: $ua"
pass "T6: multiple versions → picks highest (0.2.2), detects 0.3.0 update"

# ── T7: default discovery searches Codex plugin cache ────────────────

proj="$FIXTURE/t7"
mkdir -p "$proj"
home="$FIXTURE/home-t7"
codex_plugins="$home/.codex/plugins/cache"
make_manifest "$codex_plugins" "0.4.0"
make_fake_gh "$FIXTURE/bin-t7" "v0.4.0"
HOME="$home" \
  PATH="$FIXTURE/bin-t7:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T7" "cache file not written"
err=$(cache_field "$cache" error)
iv=$(cache_field "$cache" installed_version)
[ "$err" = "" ]      || fail "T7" "expected error=null, got: $err"
[ "$iv" = "0.4.0" ] || fail "T7" "expected installed_version=0.4.0 from Codex cache, got: $iv"
pass "T7: default discovery finds arboretum in ~/.codex/plugins/cache"

# ── T8: default discovery does not merge Codex + Claude versions ──────

proj="$FIXTURE/t8"
mkdir -p "$proj"
home="$FIXTURE/home-t8"
codex_plugins="$home/.codex/plugins/cache"
claude_plugins="$home/.claude/plugins/cache"
make_manifest "$codex_plugins" "0.4.0"
make_manifest "$claude_plugins" "9.9.9"
make_fake_gh "$FIXTURE/bin-t8" "v0.5.0"
HOME="$home" \
  PATH="$FIXTURE/bin-t8:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T8" "cache file not written"
iv=$(cache_field "$cache" installed_version)
ua=$(cache_field "$cache" update_available)
[ "$iv" = "0.4.0" ] || fail "T8" "expected Codex installed_version=0.4.0, got: $iv"
[ "$ua" = "True" ] || fail "T8" "expected Codex 0.4.0 vs latest 0.5.0 to report update_available=True, got: $ua"
pass "T8: default discovery prefers Codex cache over higher Claude install"

# ── T9: Claude sessions prefer Claude plugin cache ────────────────────

proj="$FIXTURE/t9"
mkdir -p "$proj"
home="$FIXTURE/home-t9"
codex_plugins="$home/.codex/plugins/cache"
claude_plugins="$home/.claude/plugins/cache"
make_manifest "$codex_plugins" "9.9.9"
make_manifest "$claude_plugins" "0.4.0"
make_fake_gh "$FIXTURE/bin-t9" "v0.5.0"
HOME="$home" \
  CLAUDE_PROJECT_DIR="$proj" \
  PATH="$FIXTURE/bin-t9:$ISOLATED_BIN" \
  bash "$REFRESH" "$proj" >/dev/null 2>&1 || true
cache="$proj/.arboretum/update-cache.json"
[ -f "$cache" ] || fail "T9" "cache file not written"
iv=$(cache_field "$cache" installed_version)
ua=$(cache_field "$cache" update_available)
[ "$iv" = "0.4.0" ] || fail "T9" "expected Claude installed_version=0.4.0, got: $iv"
[ "$ua" = "True" ] || fail "T9" "expected Claude 0.4.0 vs latest 0.5.0 to report update_available=True, got: $ua"
pass "T9: Claude session discovery prefers Claude cache over higher Codex install"

echo "All smoke tests passed."
exit 0
