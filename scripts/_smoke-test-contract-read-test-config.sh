#!/usr/bin/env bash
# owner: test-infrastructure
# scope: plugin-only
# _smoke-test-contract-read-test-config.sh — Contract test for
# docs/contracts/test-infrastructure.contract.md. Asserts TC-1..TC-10
# against scripts/read-test-config.sh using mktemp spec fixtures.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/read-test-config.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

SPEC="$FIX/spec.md"

# A fully-valid declaration (used by TC-1, TC-2, TC-8, TC-9).
write_valid() {
  cat > "$SPEC" <<'EOF'
---
runner: pytest
default-command: scripts/run-tests.sh
opt-in-commands:
  live: pytest -m live
  costly: pytest -m eval
layout: by-feature
tiers-via: markers
---
# body
EOF
}

# TC-1 — all valid → exit 0, scalar keys present
write_valid
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 0 ] \
   && printf '%s\n' "$out" | grep -qx 'default-command=scripts/run-tests.sh' \
   && printf '%s\n' "$out" | grep -qx 'runner=pytest' \
   && printf '%s\n' "$out" | grep -qx 'layout=by-feature' \
   && printf '%s\n' "$out" | grep -qx 'tiers-via=markers'; then
  pass TC-1
else
  fail_case TC-1 "rc=$rc out=$out err=$(cat "$FIX/.err")"
fi

# TC-2 — opt-in-commands flattened; no bare opt-in-commands= line
if printf '%s\n' "$out" | grep -qx 'opt-in-commands.live=pytest -m live' \
   && printf '%s\n' "$out" | grep -qx 'opt-in-commands.costly=pytest -m eval' \
   && ! printf '%s\n' "$out" | grep -qx 'opt-in-commands='; then
  pass TC-2
else
  fail_case TC-2 "out=$out"
fi

# TC-3 — missing default-command → exit 2, no stdout, stderr diagnostic
cat > "$SPEC" <<'EOF'
---
runner: pytest
layout: by-feature
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && [ -s "$FIX/.err" ] && pass TC-3 || fail_case TC-3 "rc=$rc out=$out"

# TC-4 — tiers-via out of enum → exit 2
cat > "$SPEC" <<'EOF'
---
default-command: make test
tiers-via: vibes
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass TC-4 || fail_case TC-4 "rc=$rc out=$out"

# TC-5 — opt-in-commands key out of enum → exit 2
cat > "$SPEC" <<'EOF'
---
default-command: make test
opt-in-commands:
  eval: pytest -m eval
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass TC-5 || fail_case TC-5 "rc=$rc out=$out"

# TC-6a — missing file → exit 1
out=$(bash "$PROBE" "$FIX/does-not-exist.md" 2>"$FIX/.err"); rc=$?
[ "$rc" = 1 ] && pass TC-6a || fail_case TC-6a "rc=$rc out=$out"
# TC-6b — file with no frontmatter at all → exit 2
printf '# just a heading\nno frontmatter\n' > "$SPEC"
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass TC-6b || fail_case TC-6b "rc=$rc out=$out"

# TC-7 — optional fields absent → only default-command emitted, no empty optional lines
cat > "$SPEC" <<'EOF'
---
default-command: npx vitest run
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 0 ] \
   && printf '%s\n' "$out" | grep -qx 'default-command=npx vitest run' \
   && [ "$(printf '%s\n' "$out" | grep -c '=')" = 1 ]; then
  pass TC-7
else
  fail_case TC-7 "rc=$rc out=$out"
fi

# TC-8 — read-only
write_valid
before=$(shasum "$SPEC" | cut -d' ' -f1); bash "$PROBE" "$SPEC" >/dev/null 2>&1
after=$(shasum "$SPEC" | cut -d' ' -f1)
[ "$before" = "$after" ] && pass TC-8 || fail_case TC-8 "spec mutated"

# TC-9 — quoted default-command printed unquoted
cat > "$SPEC" <<'EOF'
---
default-command: "pytest -m 'not live and not eval'"
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx "default-command=pytest -m 'not live and not eval'" \
  && pass TC-9 || fail_case TC-9 "rc=$rc out=$out"

# TC-10 — full-line comments inside frontmatter are ignored (the template's
# comment style); value lines are read normally.
cat > "$SPEC" <<'EOF'
---
# this is a full-line comment and must be ignored
runner: pytest
# another comment between fields
default-command: make test
tiers-via: markers
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 0 ] \
   && printf '%s\n' "$out" | grep -qx 'default-command=make test' \
   && printf '%s\n' "$out" | grep -qx 'tiers-via=markers' \
   && ! printf '%s\n' "$out" | grep -q '#'; then
  pass TC-10
else
  fail_case TC-10 "rc=$rc out=$out"
fi

# TC-11 — an unfilled angle-bracket placeholder default-command → exit 2
cat > "$SPEC" <<'EOF'
---
default-command: <command that runs the default-safe suite; exit 0 == green>
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && pass TC-11 || fail_case TC-11 "rc=$rc out=$out"

# TC-12 — dict-shaped tiers-via → exit 2 (not silently flattened)
cat > "$SPEC" <<'EOF'
---
default-command: make test
tiers-via:
  foo: bar
---
EOF
out=$(bash "$PROBE" "$SPEC" 2>"$FIX/.err"); rc=$?
[ "$rc" = 2 ] && pass TC-12 || fail_case TC-12 "rc=$rc out=$out"

[ "$fail" = 0 ] && echo "read-test-config contract: ALL PASS" || exit 1
