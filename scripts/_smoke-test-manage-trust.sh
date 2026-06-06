#!/usr/bin/env bash
# owner: pipeline-state-tracking
# _smoke-test-manage-trust.sh — Verify scripts/manage-trust.sh instantiate
# (additive-only, no clobber) and set (authoritative replace).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MGR="$SCRIPT_DIR/manage-trust.sh"
READER="$SCRIPT_DIR/read-trust-config.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# Case 1: instantiate on an absent key appends the block with given logins.
cat > "$TMP/a.yml" <<'YML'
layer: 2
backend: github
YML
bash "$MGR" instantiate "$TMP/a.yml" alice bob || fail "case 1 — instantiate should succeed"
out=$(bash "$READER" "$TMP/a.yml")
echo "$out" | grep -qx 'present=yes' || fail "case 1 — key should now be present" "$out"
echo "$out" | grep -qx 'author=alice' || fail "case 1 — alice missing" "$out"
echo "$out" | grep -qx 'author=bob' || fail "case 1 — bob missing" "$out"
grep -qx 'layer: 2' "$TMP/a.yml" || fail "case 1 — existing config must be preserved"
ok "case 1 — instantiate appends, preserves existing config"

# Case 2: instantiate is additive-only — never clobbers an existing allowlist.
before=$(cat "$TMP/a.yml")
bash "$MGR" instantiate "$TMP/a.yml" carol || fail "case 2 — should exit 0 (no-op)"
after=$(cat "$TMP/a.yml")
[ "$before" = "$after" ] || fail "case 2 — file must be byte-identical (no clobber)" "$after"
out=$(bash "$READER" "$TMP/a.yml")
echo "$out" | grep -q 'author=carol' && fail "case 2 — carol must NOT have been added" "$out"
ok "case 2 — instantiate never clobbers an existing key"

# Case 3: set replaces the allowlist (add + remove).
bash "$MGR" set "$TMP/a.yml" dave || fail "case 3 — set should succeed"
out=$(bash "$READER" "$TMP/a.yml")
echo "$out" | grep -qx 'author=dave' || fail "case 3 — dave missing" "$out"
echo "$out" | grep -q 'author=alice' && fail "case 3 — alice should be removed by set" "$out"
ok "case 3 — set replaces the list"

# Case 4: set on an absent-key file creates the block.
cat > "$TMP/d.yml" <<'YML'
layer: 1
YML
bash "$MGR" set "$TMP/d.yml" eve || fail "case 4 — set should succeed on absent key"
out=$(bash "$READER" "$TMP/d.yml")
echo "$out" | grep -qx 'present=yes' || fail "case 4 — key should be present after set" "$out"
echo "$out" | grep -qx 'author=eve' || fail "case 4 — eve missing" "$out"
grep -qx 'layer: 1' "$TMP/d.yml" || fail "case 4 — existing config preserved"
ok "case 4 — set creates block when absent"

# Case 5: default instantiate (no logins) seeds the bot at minimum.
cat > "$TMP/e.yml" <<'YML'
layer: 0
YML
bash "$MGR" instantiate "$TMP/e.yml" >/dev/null 2>&1 || fail "case 5 — default instantiate should succeed"
grep -Fq 'github-actions[bot]' "$TMP/e.yml" || fail "case 5 — bot should be seeded by default" "$(cat "$TMP/e.yml")"
ok "case 5 — default instantiate seeds bot"

# Case 6: invalid login handles are rejected before any write (#249 review).
cat > "$TMP/f.yml" <<'YML'
layer: 0
YML
before=$(cat "$TMP/f.yml")
# A login containing a colon would inject YAML structure.
bash "$MGR" set "$TMP/f.yml" 'evil: injected' 2>/dev/null \
  && fail "case 6 — colon-bearing login must be rejected"
[ "$(cat "$TMP/f.yml")" = "$before" ] || fail "case 6 — config must be untouched on rejection"
# The legitimate bot handle (with [bot] suffix) must still validate.
bash "$MGR" set "$TMP/f.yml" 'github-actions[bot]' alice || fail "case 6 — valid handles must pass"
grep -Fq 'github-actions[bot]' "$TMP/f.yml" || fail "case 6 — bot handle should be written"
ok "case 6 — invalid logins rejected, valid handles (incl. [bot]) accepted"

# Case 7: `set` preserves an UNRELATED user comment adjacent to the trust block
# (#249 review, Copilot [3] — must not delete arbitrary contiguous comments).
cat > "$TMP/g.yml" <<'YML'
layer: 0

# This is an important project note the user wrote by hand.
trust:
  journey_log_authors:
    - old-login
YML
bash "$MGR" set "$TMP/g.yml" new-login || fail "case 7 — set should succeed"
grep -Fq 'important project note the user wrote' "$TMP/g.yml" \
  || fail "case 7 — unrelated user comment must be preserved" "$(cat "$TMP/g.yml")"
out=$(bash "$READER" "$TMP/g.yml")
echo "$out" | grep -qx 'author=new-login' || fail "case 7 — new-login should be written" "$out"
echo "$out" | grep -q 'author=old-login' && fail "case 7 — old-login should be replaced" "$out"
ok "case 7 — set preserves unrelated user comments, replaces the list"

# Case 8: a malformed config makes instantiate FAIL LOUDLY, not treat as absent
# (#249 review, Copilot [2]).
printf 'trust:\n  journey_log_authors:\n   - a\n  - b\nbad: : :\n' > "$TMP/h.yml"
bash "$MGR" instantiate "$TMP/h.yml" x 2>/dev/null \
  && fail "case 8 — instantiate must fail on malformed config, not append"
ok "case 8 — malformed config fails loudly (no blind append)"

echo "ALL manage-trust smoke tests passed."
