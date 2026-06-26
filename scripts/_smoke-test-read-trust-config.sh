#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# ci-parallel: safe
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

# Case 5: flow-style allowlist → present=yes (derived from parsed rows, since
# the key is not on its own line). Regression for the #249 review hole where a
# configured flow-style allowlist read as present=no and disabled strict mode.
cat > "$TMP/flow.yml" <<'YML'
layer: 1
trust: {journey_log_authors: [alice, bob]}
YML
out=$(bash "$READER" "$TMP/flow.yml") || fail "case 5 — should succeed" "$out"
echo "$out" | grep -qx 'present=yes' || fail "case 5 — flow-style must be present=yes" "$out"
echo "$out" | grep -qx 'author=alice' || fail "case 5 — alice missing" "$out"
echo "$out" | grep -qx 'author=bob' || fail "case 5 — bob missing" "$out"
ok "case 5 — flow-style allowlist recognized as present"

# Case 6: empty flow-style allowlist → present=yes (explicit trust-nobody),
# zero authors. Regression for #598 (empty flow read as absent → permissive).
cat > "$TMP/ef.yml" <<'YML'
layer: 1
trust: {journey_log_authors: []}
YML
out=$(bash "$READER" "$TMP/ef.yml") || fail "case 6 — should succeed" "$out"
echo "$out" | grep -qx 'present=yes' || fail "case 6 — empty flow must be present=yes" "$out"
echo "$out" | grep -q '^author=' && fail "case 6 — expected zero authors" "$out"
ok "case 6 — empty flow-style allowlist is present (strict trust-nobody)"

# Case 7: a commented-out mention must NOT count as present.
cat > "$TMP/cm.yml" <<'YML'
layer: 1
# journey_log_authors: not-real
YML
out=$(bash "$READER" "$TMP/cm.yml") || fail "case 7 — should succeed" "$out"
echo "$out" | grep -qx 'present=no' || fail "case 7 — commented mention must be present=no" "$out"
ok "case 7 — commented-out key does not false-positive"

echo "ALL read-trust-config smoke tests passed."
