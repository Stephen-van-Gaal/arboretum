#!/usr/bin/env bash
# owner: pipeline-state-tracking
# _smoke-test-read-trust-config.sh — Verify scripts/read-trust-config.sh
# parses trust.journey_log_authors and reports present/absent correctly.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/read-trust-config.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# Case 1: populated list → present=yes + both logins.
cat > "$TMP/a.yml" <<'YML'
layer: 2
trust:
  journey_log_authors:
    - stvangaal
    - github-actions[bot]
YML
out=$(bash "$READER" "$TMP/a.yml") || fail "case 1 — should succeed" "$out"
echo "$out" | grep -qx 'present=yes' || fail "case 1 — expected present=yes" "$out"
echo "$out" | grep -qx 'author=stvangaal' || fail "case 1 — expected stvangaal" "$out"
echo "$out" | grep -Fqx 'author=github-actions[bot]' || fail "case 1 — expected bot" "$out"
ok "case 1 — populated list parsed"

# Case 2: empty list → present=yes, zero authors (explicit trust-nobody).
cat > "$TMP/b.yml" <<'YML'
trust:
  journey_log_authors: []
YML
out=$(bash "$READER" "$TMP/b.yml") || fail "case 2 — should succeed" "$out"
echo "$out" | grep -qx 'present=yes' || fail "case 2 — empty list is still present" "$out"
echo "$out" | grep -q '^author=' && fail "case 2 — expected zero authors" "$out"
ok "case 2 — empty list = present, no authors"

# Case 3: absent key → present=no.
cat > "$TMP/c.yml" <<'YML'
layer: 2
backend: github
YML
out=$(bash "$READER" "$TMP/c.yml") || fail "case 3 — should succeed" "$out"
echo "$out" | grep -qx 'present=no' || fail "case 3 — expected present=no" "$out"
ok "case 3 — absent key reported"

# Case 4: missing config file → non-zero exit.
bash "$READER" "$TMP/does-not-exist.yml" 2>/dev/null && fail "case 4 — should fail on missing file"
ok "case 4 — missing file exits non-zero"

echo "ALL read-trust-config smoke tests passed."
