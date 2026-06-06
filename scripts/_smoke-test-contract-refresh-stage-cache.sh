#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-refresh-stage-cache.sh — Contract test for
# docs/contracts/refresh-stage-cache.contract.md. Asserts RSC-1..RSC-8 from
# the contract's ## Test surface against scripts/refresh-stage-cache.sh.
#
# Fixture pattern (mirrors scripts/_smoke-test-refresh-stage-cache.sh): mktemp -d
# a real git repo with a github origin, shadow PATH with a gh stub that reads its
# canned responses from env-var-pointed files, run the producer, assert the
# written active-stage-cache.json shape.
#
# Asserts existing behaviour only — green immediately. Never modifies a script.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-stage-cache.sh"
[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH not found" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  fail=1
}

new_repo() {
  local fix="$ROOT_TMP/$1"
  mkdir -p "$fix/.arboretum" "$fix/docs/superpowers/specs"
  git -C "$fix" init -q
  git -C "$fix" config user.email "f@e.com"; git -C "$fix" config user.name f
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m seed
  git -C "$fix" remote add origin "https://github.com/example/repo.git"
  echo "$fix"
}

install_gh_stub() {
  local bindir="$1/.bin"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue view")
    # Stage lives in a stage:* label; the producer reads it via
    # --json labels --jq '.labels[].name'. Honor that arm by emitting the
    # fixture label set from $GH_STUB_LABELS (a file of newline-separated
    # names, so control chars / quotes survive byte-for-byte).
    case "$*" in
      *--json\ labels*) cat "${GH_STUB_LABELS:-/dev/null}" 2>/dev/null; exit 0 ;;
    esac
    cat "${GH_STUB_BODY:-/dev/null}" 2>/dev/null \
      || echo '{"body":"## Context","number":307,"title":"WS9"}'
    exit 0 ;;
  "issue list")
    cat "${GH_STUB_ISSUES:-/dev/null}" 2>/dev/null || echo '[]'
    exit 0 ;;
  "api "*)
    echo '[]'
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$bindir/gh"
  echo "$bindir"
}

# ── RSC-2 / RSC-1: degraded path — gh absent → null cache ─────────────
# Hide gh robustly: mirror EVERY PATH executable except gh into a shadow bin,
# so `command -v gh` fails on every platform regardless of where gh lives.
# (Dir-stripping left gh reachable in CI where gh shares /usr/bin with the
# tools we must keep; mirroring-all-but-gh avoids guessing an allowlist.)
c_deg=$(new_repo deg)
NOGH_BIN="$ROOT_TMP/nogh-bin"; mkdir -p "$NOGH_BIN"
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
PATH="$NOGH_BIN" bash "$REFRESH" "$c_deg" >/dev/null 2>&1
deg_exit=$?
deg_cache="$c_deg/.arboretum/active-stage-cache.json"
if [ "$deg_exit" -eq 0 ] && [ -f "$deg_cache" ]; then
  pass "RSC-1/RSC-2: gh-absent degraded path exits 0 and writes a cache"
else
  fail_case "RSC-1/RSC-2: degraded path exit=$deg_exit, cache present=$( [ -f "$deg_cache" ] && echo yes || echo no )"
fi
deg_res=$(python3 -c "
import json
c = json.load(open('$deg_cache'))
keys = set(c.keys())
problems = []
if keys != {'issue','stage','ts'}: problems.append('keys=%r' % keys)
if c.get('issue') is not None: problems.append('issue not null: %r' % c.get('issue'))
if c.get('stage') is not None: problems.append('stage not null: %r' % c.get('stage'))
if not c.get('ts'): problems.append('ts missing/empty')
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$deg_res" = "OK" ]; then
  pass "RSC-2: degraded cache has exactly {issue,stage,ts}, issue+stage null, ts present"
else
  fail_case "RSC-2: degraded cache shape wrong" "$deg_res"
fi

# ── RSC-3: branch-resolution happy path → issue int + stage ───────────
c3=$(new_repo c3)
bindir=$(install_gh_stub "$c3")
git -C "$c3" checkout -q -b feat/foo-bar-build
cat > "$c3/docs/superpowers/specs/2026-05-23-foo-bar-design.md" <<'SPEC'
---
related-issue: 999
---
# foo-bar
SPEC
printf 'stage:build\nagent-ready\n' > "$c3/labels.txt"
GH_STUB_LABELS="$c3/labels.txt" PATH="$bindir:$PATH" bash "$REFRESH" "$c3" >/dev/null 2>&1
c3_res=$(python3 -c "
import json
c = json.load(open('$c3/.arboretum/active-stage-cache.json'))
problems = []
if c.get('issue') != 999: problems.append('issue=%r (expected 999 int)' % c.get('issue'))
if not isinstance(c.get('issue'), int): problems.append('issue not an int')
if c.get('stage') != '/build': problems.append('stage=%r (expected /build)' % c.get('stage'))
if 'ts' not in c: problems.append('ts missing')
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$c3_res" = "OK" ]; then
  pass "RSC-3/RSC-4: branch feat/foo-bar-build resolves design spec → issue:999(int), stage:/build"
else
  fail_case "RSC-3/RSC-4: branch resolution wrong" "$c3_res"
fi

# ── RSC-5: issue resolved, no stage:* label → stage null ──────────────
c5=$(new_repo c5)
bindir=$(install_gh_stub "$c5")
git -C "$c5" checkout -q -b feat/no-stage-build
cat > "$c5/docs/superpowers/specs/2026-05-23-no-stage-design.md" <<'SPEC'
---
related-issue: 111
---
SPEC
printf 'agent-ready\n' > "$c5/labels.txt"
GH_STUB_LABELS="$c5/labels.txt" PATH="$bindir:$PATH" bash "$REFRESH" "$c5" >/dev/null 2>&1
c5_res=$(python3 -c "
import json
c = json.load(open('$c5/.arboretum/active-stage-cache.json'))
problems = []
if c.get('issue') != 111: problems.append('issue=%r (expected 111)' % c.get('issue'))
if c.get('stage') is not None: problems.append('stage=%r (expected null)' % c.get('stage'))
print('OK' if not problems else ' | '.join(problems))
" 2>&1)
if [ "$c5_res" = "OK" ]; then
  pass "RSC-5: issue resolved but no stage:* label → issue:111, stage:null"
else
  fail_case "RSC-5: no-stage-label case wrong" "$c5_res"
fi

# ── RSC-6: ANSI-scrub — control char in stage stripped at write ───────
c6=$(new_repo c6)
bindir=$(install_gh_stub "$c6")
git -C "$c6" checkout -q -b feat/evil-stage-build
cat > "$c6/docs/superpowers/specs/2026-05-23-evil-stage-design.md" <<'SPEC'
---
related-issue: 222
---
SPEC
# Stage:* label name with an embedded ESC (\x1b) control char. The producer
# scrubs the derived stage value before serializing, so the ESC must not
# survive into the cache. Write the fixture via python3 so the raw byte lands.
python3 -c "
open('$c6/labels.txt','w').write('stage:bu\x1bild\n')
"
GH_STUB_LABELS="$c6/labels.txt" PATH="$bindir:$PATH" bash "$REFRESH" "$c6" >/dev/null 2>&1
c6_res=$(python3 -c "
import json
c = json.load(open('$c6/.arboretum/active-stage-cache.json'))
stage = c.get('stage') or ''
if c.get('issue') != 222:
    print('FAIL: issue=%r (expected 222)' % c.get('issue'))
elif '\x1b' in stage:
    print('FAIL: ESC still present in stage: %r' % stage)
elif 'bu' not in stage or 'ild' not in stage:
    print('FAIL: readable content lost: %r' % stage)
else:
    print('OK: %r' % stage)
" 2>&1)
if echo "$c6_res" | grep -q '^OK:'; then
  pass "RSC-6: control char stripped from stage at write, readable content preserved"
else
  fail_case "RSC-6: ANSI scrub on stage failed" "$c6_res"
fi

# ── RSC-7: JSON-safety — a double-quote in the stage token doesn't break JSON ──
c7=$(new_repo c7)
bindir=$(install_gh_stub "$c7")
git -C "$c7" checkout -q -b feat/quote-stage-build
cat > "$c7/docs/superpowers/specs/2026-05-23-quote-stage-design.md" <<'SPEC'
---
related-issue: 333
---
SPEC
# A stage:* label name carrying a double-quote and backslash. The producer
# serializes the derived stage via json.dumps, so these must not break the
# cache JSON. Write the fixture via python3 so the raw bytes land verbatim.
python3 -c "
open('$c7/labels.txt','w').write('stage:a\"b\\\\c\n')
"
GH_STUB_LABELS="$c7/labels.txt" PATH="$bindir:$PATH" bash "$REFRESH" "$c7" >/dev/null 2>&1
c7_res=$(python3 -c "
import json
try:
    c = json.load(open('$c7/.arboretum/active-stage-cache.json'))
except Exception as ex:
    print('FAIL: cache not valid JSON: %s' % ex); raise SystemExit
if c.get('issue') != 333:
    print('FAIL: issue=%r' % c.get('issue'))
else:
    print('OK: parseable, stage=%r' % c.get('stage'))
" 2>&1)
if echo "$c7_res" | grep -q '^OK:'; then
  pass "RSC-7: stage with embedded quote/backslash keeps cache valid JSON (json.dumps serialization)"
else
  fail_case "RSC-7: JSON-safety failed" "$c7_res"
fi

# ── RSC-8: atomic-write — write_cache() uses mktemp + mv ──────────────
write_cache_body=$(awk '
  /^write_cache\(\)/ { in_fn=1; next }
  in_fn && /^}$/ { in_fn=0 }
  in_fn { print }
' "$REFRESH")
if echo "$write_cache_body" | grep -qE 'mktemp[[:space:]]+"\$CACHE_DIR' \
   && echo "$write_cache_body" | grep -qE 'mv[[:space:]]+"\$tmp"[[:space:]]+"\$CACHE_FILE"'; then
  pass "RSC-8 (atomic-write): write_cache() uses mktemp + atomic mv discipline"
else
  fail_case "RSC-8: write_cache() does not match mktemp + mv pattern" "$write_cache_body"
fi

# ── Summary ───────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
  echo "All refresh-stage-cache contract assertions passed."
  exit 0
else
  echo "Some refresh-stage-cache contract assertions failed." >&2
  exit 1
fi
