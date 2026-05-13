#!/usr/bin/env bash
# _smoke-test-generate-register-empty-owns.sh — regression test for
# generate-register.sh's empty-owns handling.
#
# generate-register.sh uses `set -u`. Inside extract_owns_list, the
# local `patterns=()` array stays empty when a spec has no owns: block
# (or an inline `owns: []`). Expanding `"${patterns[@]}"` from an empty
# array under set -u trips bash with:
#
#   patterns[@]: unbound variable
#
# The script still writes REGISTER.md (the trap doesn't fire because
# the expansion is the final command), so the failure can be missed.
# This test fails LOUDLY if the unbound-variable expansion is reintroduced.
#
# Usage: bash scripts/_smoke-test-generate-register-empty-owns.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"

[ -f "$GEN" ] || { echo "FAIL: $GEN not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Build fixture project ────────────────────────────────────────────

mkdir -p "$FIXTURE/docs/specs"

# Spec with NO owns: block at all — the trigger.
cat > "$FIXTURE/docs/specs/empty-owns.spec.md" <<'EOF'
---
name: empty-owns
status: active
owner: alice
---

# empty-owns

A spec that declares no owned files. Should produce a valid (empty-owns)
row in REGISTER.md without tripping `set -u` on the empty patterns array.
EOF

# Spec with inline empty list — the other trigger.
cat > "$FIXTURE/docs/specs/inline-empty.spec.md" <<'EOF'
---
name: inline-empty
status: active
owner: bob
owns: []
---

# inline-empty
EOF

# Healthy spec alongside, so the script has a non-empty case to render too.
cat > "$FIXTURE/docs/specs/normal.spec.md" <<'EOF'
---
name: normal
status: active
owner: carol
owns:
  - src/normal.py
---

# normal
EOF

# ── Run generate-register.sh ─────────────────────────────────────────

stderr_log=$(mktemp)
trap 'rm -rf "$FIXTURE" "$stderr_log"' EXIT

if ! bash "$GEN" "$FIXTURE" >/dev/null 2>"$stderr_log"; then
  fail "generate-register.sh exited non-zero against empty-owns fixture" "$(cat "$stderr_log")"
fi

# ── Assertions ───────────────────────────────────────────────────────

# 1. No "unbound variable" noise on stderr.
if grep -q 'unbound variable' "$stderr_log"; then
  fail "generate-register.sh emitted 'unbound variable' on stderr" "$(cat "$stderr_log")"
fi

# 2. REGISTER.md was produced.
register="$FIXTURE/docs/REGISTER.md"
[ -f "$register" ] || fail "REGISTER.md not generated"

# 3. Both empty-owns specs appear in the register, signalling they were
#    not silently dropped by an early-exit during the unbound expansion.
grep -q 'empty-owns.spec.md'  "$register" || fail "empty-owns spec missing from REGISTER.md" "$(cat "$register")"
grep -q 'inline-empty.spec.md' "$register" || fail "inline-empty spec missing from REGISTER.md" "$(cat "$register")"
grep -q 'normal.spec.md'       "$register" || fail "normal spec missing from REGISTER.md" "$(cat "$register")"

echo "OK: generate-register.sh handles empty owns: blocks without unbound-variable noise."
