#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-refresh-update-cache.sh — Contract test for
# docs/contracts/refresh-update-cache.contract.md. Asserts RUC-1..RUC-7 from
# the contract's ## Test surface against scripts/refresh-update-cache.sh.
#
# Fixture pattern: mktemp -d a project root + a fake plugin cache (pointed at by
# ARBORETUM_PLUGIN_CACHE), shadow PATH with a gh stub whose tagName response is
# env-driven, run the producer, assert the written update-cache.json shape.
#
# Asserts existing behaviour only — green immediately. Never modifies a script.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-update-cache.sh"
[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

# Build a fake plugin cache containing an arboretum plugin.json at $1 version.
make_plugin_cache() {
  local dir="$1" ver="$2"
  mkdir -p "$dir/arboretum-marketplace/arboretum"
  cat > "$dir/arboretum-marketplace/arboretum/plugin.json" <<EOF
{ "name": "arboretum", "version": "$ver" }
EOF
}

# gh stub: `gh release view ... --jq '.tagName'` prints \$GH_TAG; can fail via \$GH_FAIL.
make_gh_stub() {
  local bindir="$1"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${GH_FAIL:-0}" = "1" ]; then
  echo "release not found" >&2
  exit 1
fi
case "$1 $2" in
  "release view") printf '%s' "${GH_TAG:-}" ;;
esac
exit 0
STUB
  chmod +x "$bindir/gh"
}

EMPTY_CACHE_KEYS='fetched_at installed_version latest_version update_available error'

assert_keys() {
  # $1 = cache path
  python3 -c "
import json
c = json.load(open('$1'))
expected = {'fetched_at','installed_version','latest_version','update_available','error'}
actual = set(c.keys())
print('OK' if actual == expected else ('missing:%r extra:%r' % (expected-actual, actual-expected)))
"
}

# ── RUC-1 / RUC-2: manifest-not-found (empty plugin cache) ────────────
P1="$ROOT/p1"; mkdir -p "$P1"
EMPTY_PLUGINS="$ROOT/empty-plugins"; mkdir -p "$EMPTY_PLUGINS"
ARBORETUM_PLUGIN_CACHE="$EMPTY_PLUGINS" bash "$REFRESH" "$P1" >/dev/null 2>&1
r1_exit=$?
C1="$P1/.arboretum/update-cache.json"
if [ "$r1_exit" -eq 0 ] && [ -f "$C1" ]; then
  pass "RUC-1: manifest-not-found exits 0 and writes a cache"
else
  fail_case "RUC-1: exit=$r1_exit cache=$( [ -f "$C1" ] && echo yes || echo no )"
fi
r1_keys=$(assert_keys "$C1" 2>&1)
if [ "$r1_keys" = "OK" ]; then
  pass "RUC-2: cache has exactly {$EMPTY_CACHE_KEYS}"
else
  fail_case "RUC-2: key mismatch" "$r1_keys"
fi
r1_res=$(python3 -c "
import json
c = json.load(open('$C1'))
p = []
if c.get('error') != 'manifest-not-found': p.append('error=%r' % c.get('error'))
if c.get('installed_version') is not None: p.append('installed_version=%r' % c.get('installed_version'))
if c.get('latest_version') is not None: p.append('latest_version=%r' % c.get('latest_version'))
if c.get('update_available') is not False: p.append('update_available=%r' % c.get('update_available'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$r1_res" = "OK" ]; then
  pass "RUC-1: error=manifest-not-found, versions null, update_available false"
else
  fail_case "RUC-1: field values wrong" "$r1_res"
fi

# ── RUC-3: gh-unavailable → error gh-unavailable, exit 1, cache written ──
P3="$ROOT/p3"; mkdir -p "$P3"
PC3="$ROOT/pc3"; make_plugin_cache "$PC3" "0.1.0"
# Hide gh robustly: mirror EVERY PATH executable except gh into a shadow bin,
# so `command -v gh` fails on every platform regardless of where gh lives.
# (The prior dir-stripping approach left gh reachable in CI, where gh shares
# /usr/bin with git/python3 — RUC-3 then hit the gh-call-failed path, exit 0.
# Mirroring-all-but-gh avoids guessing an allowlist that omits a needed tool.)
NOGH_BIN="$ROOT/nogh-bin"; mkdir -p "$NOGH_BIN"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = gh ] && continue
    [ -e "$NOGH_BIN/$_b" ] || ln -s "$_f" "$NOGH_BIN/$_b" 2>/dev/null || true
  done
done
PATH="$NOGH_BIN" ARBORETUM_PLUGIN_CACHE="$PC3" bash "$REFRESH" "$P3" >/dev/null 2>&1
r3_exit=$?
C3="$P3/.arboretum/update-cache.json"
r3_res=$(python3 -c "
import json
c = json.load(open('$C3'))
p = []
if c.get('error') != 'gh-unavailable': p.append('error=%r' % c.get('error'))
if c.get('installed_version') != '0.1.0': p.append('installed_version=%r' % c.get('installed_version'))
if c.get('update_available') is not False: p.append('update_available=%r' % c.get('update_available'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$r3_res" = "OK" ] && [ "$r3_exit" -eq 1 ]; then
  pass "RUC-3: gh-unavailable writes cache (installed=0.1.0) AND exits 1 (documented non-zero path)"
else
  fail_case "RUC-3: gh-unavailable wrong (exit=$r3_exit)" "$r3_res"
fi

# ── RUC-4: update-available happy path ────────────────────────────────
P4="$ROOT/p4"; mkdir -p "$P4"
PC4="$ROOT/pc4"; make_plugin_cache "$PC4" "0.1.0"
GHB="$ROOT/ghbin"; make_gh_stub "$GHB"
GH_TAG="v0.2.0" PATH="$GHB:$PATH" ARBORETUM_PLUGIN_CACHE="$PC4" bash "$REFRESH" "$P4" >/dev/null 2>&1
r4_exit=$?
C4="$P4/.arboretum/update-cache.json"
r4_res=$(python3 -c "
import json
c = json.load(open('$C4'))
p = []
if c.get('installed_version') != '0.1.0': p.append('installed=%r' % c.get('installed_version'))
if c.get('latest_version') != '0.2.0': p.append('latest=%r' % c.get('latest_version'))
if c.get('update_available') is not True: p.append('update_available=%r' % c.get('update_available'))
if c.get('error') is not None: p.append('error=%r' % c.get('error'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$r4_res" = "OK" ] && [ "$r4_exit" -eq 0 ]; then
  pass "RUC-4: 0.1.0 installed vs 0.2.0 latest → update_available true, error null, exit 0"
else
  fail_case "RUC-4: update-available path wrong (exit=$r4_exit)" "$r4_res"
fi

# ── RUC-5: up-to-date path ────────────────────────────────────────────
P5="$ROOT/p5"; mkdir -p "$P5"
PC5="$ROOT/pc5"; make_plugin_cache "$PC5" "0.2.0"
GH_TAG="v0.2.0" PATH="$GHB:$PATH" ARBORETUM_PLUGIN_CACHE="$PC5" bash "$REFRESH" "$P5" >/dev/null 2>&1
C5="$P5/.arboretum/update-cache.json"
r5_res=$(python3 -c "
import json
c = json.load(open('$C5'))
p = []
if c.get('update_available') is not False: p.append('update_available=%r' % c.get('update_available'))
if c.get('error') is not None: p.append('error=%r' % c.get('error'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$r5_res" = "OK" ]; then
  pass "RUC-5: installed == latest → update_available false, error null"
else
  fail_case "RUC-5: up-to-date path wrong" "$r5_res"
fi

# ── RUC-6: gh-call-failed / no-release path ───────────────────────────
P6="$ROOT/p6"; mkdir -p "$P6"
PC6="$ROOT/pc6"; make_plugin_cache "$PC6" "0.1.0"
GH_FAIL=1 PATH="$GHB:$PATH" ARBORETUM_PLUGIN_CACHE="$PC6" bash "$REFRESH" "$P6" >/dev/null 2>&1
r6_exit=$?
C6="$P6/.arboretum/update-cache.json"
r6_res=$(python3 -c "
import json
c = json.load(open('$C6'))
err = c.get('error')
p = []
if err not in ('no-release','gh-call-failed'): p.append('error=%r (expected no-release|gh-call-failed)' % err)
if c.get('update_available') is not False: p.append('update_available=%r' % c.get('update_available'))
print('OK' if not p else ' | '.join(p))
" 2>&1)
if [ "$r6_res" = "OK" ] && [ "$r6_exit" -eq 0 ]; then
  pass "RUC-6: gh release failure → error in {no-release,gh-call-failed}, update_available false, exit 0"
else
  fail_case "RUC-6: gh-failure path wrong (exit=$r6_exit)" "$r6_res"
fi

# ── RUC-7: atomic-write — write_cache() uses mktemp + mv ──────────────
write_cache_body=$(awk '
  /^write_cache\(\)/ { in_fn=1; next }
  in_fn && /^}$/ { in_fn=0 }
  in_fn { print }
' "$REFRESH")
if echo "$write_cache_body" | grep -qE 'mktemp[[:space:]]+"\$CACHE_DIR' \
   && echo "$write_cache_body" | grep -qE 'mv[[:space:]]+"\$tmp"[[:space:]]+"\$CACHE_FILE"'; then
  pass "RUC-7 (atomic-write): write_cache() uses mktemp + atomic mv discipline"
else
  fail_case "RUC-7: write_cache() does not match mktemp + mv pattern" "$write_cache_body"
fi

# ── Summary ───────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  echo "All refresh-update-cache contract assertions passed."
  exit 0
else
  echo "Some refresh-update-cache contract assertions failed." >&2
  exit 1
fi
