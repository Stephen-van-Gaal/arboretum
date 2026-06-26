#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# ci-parallel: safe
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

# Deterministic gh stub: default-instantiate (no logins) resolves a login via
# `gh api user`. Stub it so the test does not depend on CI gh authentication.
BINDIR="$TMP/.bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$* " in
  "api user "*|"api user") echo "stubbed-runner"; exit 0 ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$BINDIR/gh"
PATH="$BINDIR:$PATH"; export PATH

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

# Case 9: `set` preserves SIBLING keys under an existing trust: block
# (#249 review, Codex [B]) — replaces only journey_log_authors.
cat > "$TMP/i.yml" <<'YML'
layer: 0
trust:
  journey_log_authors:
    - old
  some_other_setting: keep-me
YML
bash "$MGR" set "$TMP/i.yml" fresh || fail "case 9 — set should succeed"
grep -Fq 'some_other_setting: keep-me' "$TMP/i.yml" \
  || fail "case 9 — sibling trust key must be preserved" "$(cat "$TMP/i.yml")"
out=$(bash "$READER" "$TMP/i.yml")
echo "$out" | grep -qx 'author=fresh' || fail "case 9 — fresh login should be written" "$out"
echo "$out" | grep -q 'author=old' && fail "case 9 — old login should be replaced" "$out"
ok "case 9 — set preserves sibling trust keys"

# Case 10: when `gh api user` fails, default instantiate leaves the key ABSENT
# (permissive migration) instead of writing a bot-only strict block, and exits
# non-zero so callers surface "not seeded" (#249 review, Codex [E]).
FAILBIN="$TMP/.failbin"; mkdir -p "$FAILBIN"
cat > "$FAILBIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: unavailable" >&2; exit 1
STUB
chmod +x "$FAILBIN/gh"
cat > "$TMP/j.yml" <<'YML'
layer: 0
YML
if PATH="$FAILBIN:$PATH" bash "$MGR" instantiate "$TMP/j.yml" 2>/dev/null; then
  fail "case 10 — instantiate must exit non-zero when gh login unresolvable"
fi
grep -q 'journey_log_authors' "$TMP/j.yml" \
  && fail "case 10 — must NOT write a bot-only block; leave key absent" "$(cat "$TMP/j.yml")"
ok "case 10 — gh-unavailable leaves trust unconfigured (permissive), exits non-zero"

# Case 11: set fully removes old entries even when a blank line splits the list
# (#598 review, Copilot+Codex P2), and preserves a sibling key.
printf 'trust:\n  journey_log_authors:\n    - a\n\n    - b\n  sib: keep\n' > "$TMP/bl.yml"
bash "$MGR" set "$TMP/bl.yml" only || fail "case 11 — set should succeed"
grep -Eq '^[[:space:]]*- a$' "$TMP/bl.yml" && fail "case 11 — old entry a not removed" "$(cat "$TMP/bl.yml")"
grep -Eq '^[[:space:]]*- b$' "$TMP/bl.yml" && fail "case 11 — old entry b (after blank) not removed" "$(cat "$TMP/bl.yml")"
grep -Fq 'sib: keep' "$TMP/bl.yml" || fail "case 11 — sibling key lost" "$(cat "$TMP/bl.yml")"
out=$(bash "$READER" "$TMP/bl.yml"); echo "$out" | grep -qx 'author=only' || fail "case 11 — only-login missing" "$out"
ok "case 11 — set removes blank-split old entries, preserves sibling"

# Case 12: set recognizes a block-form trust: line with an inline comment.
printf 'trust: # project trust settings\n  journey_log_authors:\n    - a\n' > "$TMP/ic.yml"
bash "$MGR" set "$TMP/ic.yml" b || fail "case 12 — set should succeed with inline-comment trust line"
out=$(bash "$READER" "$TMP/ic.yml")
echo "$out" | grep -qx 'author=b' || fail "case 12 — b missing" "$out"
echo "$out" | grep -q 'author=a' && fail "case 12 — a should be replaced" "$out"
ok "case 12 — set handles inline-comment trust: line"

echo "ALL manage-trust smoke tests passed."
