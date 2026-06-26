#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-audit-test-metadata.sh — exercises the test-metadata auditor.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/scripts/audit-test-metadata.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp" "${tmp2:-/nonexistent}" "${tmp3:-/nonexistent}" 2>/dev/null; rm -rf "$tmp" "${tmp2:-}" "${tmp3:-}"' EXIT
mkdir -p "$tmp/scripts"

# isolated, read-only -> safe-candidate
cat >"$tmp/scripts/_smoke-test-iso.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"; echo hi >"$t/x"
X
# mutates working tree -> serial-required
cat >"$tmp/scripts/_smoke-test-mut.sh" <<'X'
#!/usr/bin/env bash
git add foo && git commit -m x
X
# mktemp + real network port -> needs-review
cat >"$tmp/scripts/_smoke-test-amb.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"; nc -l localhost:8080
X
# mktemp + JSON token-count number (NOT a port) -> safe-candidate, not needs-review
cat >"$tmp/scripts/_smoke-test-jsonnum.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"; echo '{"output_tokens":1000,"cache_read_input_tokens":80000}' >"$t/f"
X

# --- report mode classification ---
out="$(cd "$tmp" && bash "$AUDIT")" || fail "report mode exited non-zero"
grep -q "safe-candidate.*_smoke-test-iso.sh"  <<<"$out" || fail "iso not classified safe-candidate"
grep -q "serial-required.*_smoke-test-mut.sh" <<<"$out" || fail "mut not classified serial-required"
grep -q "needs-review.*_smoke-test-amb.sh"    <<<"$out" || fail "amb (real port) not classified needs-review"
grep -q "safe-candidate.*_smoke-test-jsonnum.sh" <<<"$out" || fail "jsonnum (token count, not a port) wrongly not safe-candidate"
echo "PASS: report-mode classification"

# --- --check enforcement ---
if (cd "$tmp" && bash "$AUDIT" --check) >/dev/null 2>&1; then fail "--check passed on untagged corpus"; fi
chk="$(cd "$tmp" && bash "$AUDIT" --check 2>&1 || true)"
grep -q "_smoke-test-iso.sh" <<<"$chk" || fail "--check did not name the untagged file"
printf '#!/usr/bin/env bash\n# ci-parallel: safe\n'   >"$tmp/scripts/_smoke-test-iso.sh"
printf '#!/usr/bin/env bash\n# ci-parallel: serial\n' >"$tmp/scripts/_smoke-test-mut.sh"
printf '#!/usr/bin/env bash\n# ci-parallel: serial\n' >"$tmp/scripts/_smoke-test-amb.sh"
printf '#!/usr/bin/env bash\n# ci-parallel: safe\n'   >"$tmp/scripts/_smoke-test-jsonnum.sh"
(cd "$tmp" && bash "$AUDIT" --check) || fail "--check failed when all declared"
echo "PASS: --check enforcement"

# --- --apply tagging ---
cat >"$tmp/scripts/_smoke-test-iso.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"
X
cat >"$tmp/scripts/_smoke-test-amb.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"; nc -l localhost:8080
X
rm -f "$tmp/scripts/_smoke-test-mut.sh"
(cd "$tmp" && bash "$AUDIT" --apply) || fail "--apply exited non-zero"
grep -q '^# ci-parallel: safe$' "$tmp/scripts/_smoke-test-iso.sh" || fail "--apply did not tag safe-candidate safe"
if grep -q '^# ci-parallel:' "$tmp/scripts/_smoke-test-amb.sh"; then fail "--apply wrongly tagged needs-review"; fi
echo "PASS: --apply tagging"

# --- --apply preserves the owner-header invariant (# owner: stays on line 2) ---
cat >"$tmp/scripts/_smoke-test-hdr.sh" <<'X'
#!/usr/bin/env bash
# owner: some-spec
# scope: plugin-only
# _smoke-test-hdr.sh — fixture
t="$(mktemp -d)"
X
(cd "$tmp" && bash "$AUDIT" --apply) >/dev/null || fail "--apply (hdr) exited non-zero"
[ "$(sed -n '2p' "$tmp/scripts/_smoke-test-hdr.sh")" = "# owner: some-spec" ] \
  || fail "--apply displaced # owner: from line 2"
owner_ln=$(grep -nE '^# owner:' "$tmp/scripts/_smoke-test-hdr.sh" | head -1 | cut -d: -f1)
par_ln=$(grep -nE '^# ci-parallel:' "$tmp/scripts/_smoke-test-hdr.sh" | head -1 | cut -d: -f1)
[ -n "$par_ln" ] && [ "$owner_ln" -lt "$par_ln" ] \
  || fail "--apply did not place # ci-parallel after # owner:"
echo "PASS: --apply preserves owner-header order"

# --- classifier routes path-scoped git (git -C/-c <verb>) to needs-review, not
#     auto-safe (Codex P2): a regex can't tell a temp sandbox from the real tree ---
tmp2="$(mktemp -d)"; mkdir -p "$tmp2/scripts"
cat >"$tmp2/scripts/_smoke-test-gitopt.sh" <<'X'
#!/usr/bin/env bash
t="$(mktemp -d)"; git -C "$PWD" add foo
X
v="$(cd "$tmp2" && bash "$AUDIT" | awk '/_smoke-test-gitopt\.sh/{print $2}')"
[ "$v" = "needs-review" ] || fail "git -C ... add not routed to needs-review (got: $v)"

# --- --check rejects an invalid ci-parallel value, not just 'untagged' (Codex P2 / Copilot) ---
printf '#!/usr/bin/env bash\n# ci-parallel: maybe\n' >"$tmp2/scripts/_smoke-test-gitopt.sh"
inv="$(cd "$tmp2" && bash "$AUDIT" --check 2>&1 || true)"
grep -q "_smoke-test-gitopt.sh" <<<"$inv" || fail "--check did not reject invalid ci-parallel value"
echo "PASS: classifier sees git options + --check rejects invalid value"

# --- --check fails (not a false 'ok') when zero smoke tests are found (Copilot) ---
tmp3="$(mktemp -d)"; mkdir -p "$tmp3/scripts"
if (cd "$tmp3" && bash "$AUDIT" --check) >/dev/null 2>&1; then fail "--check printed ok with zero smoke tests"; fi
echo "PASS: --check fails on zero smoke tests"

# --- --apply propagates a failed edit as non-zero (Codex P3) ---
printf '#!/usr/bin/env bash\n# owner: x\nt="$(mktemp -d)"\n' >"$tmp3/scripts/_smoke-test-ro.sh"
chmod 0444 "$tmp3/scripts/_smoke-test-ro.sh"; chmod 0555 "$tmp3/scripts"
if (cd "$tmp3" && bash "$AUDIT" --apply) >/dev/null 2>&1; then fail "--apply returned 0 despite a failed edit"; fi
chmod 0755 "$tmp3/scripts"
echo "PASS: --apply propagates failed edit"

# --- usage error ---
if (cd "$tmp" && bash "$AUDIT" --bogus) >/dev/null 2>&1; then fail "invalid arg did not exit non-zero"; fi
# extra arguments are a usage error too (Codex P3), not silently ignored
if (cd "$tmp" && bash "$AUDIT" --check --bogus) >/dev/null 2>&1; then fail "--check with extra arg did not exit non-zero"; fi
if (cd "$tmp" && bash "$AUDIT" --apply extra) >/dev/null 2>&1; then fail "--apply with extra arg did not exit non-zero"; fi
echo "PASS: usage error"
