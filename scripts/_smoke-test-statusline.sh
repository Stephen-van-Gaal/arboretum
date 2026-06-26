#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-statusline.sh — Verify .claude/hooks/statusline.sh renders
# the full rich line: <model> | ts HH:MM | <project>/<branch> | ctx N% |
# 5h:N% 7d:N% | wt:name | [#N /stage], with graceful omission of absent
# segments and control-char scrubbing on string fields (spec §Defense in
# depth). The ts segment is always present (issue #363).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

# The ts segment (always-present, local HH:MM) is computed at render time, so
# its exact value depends on the clock at hook-call. To keep existing case
# expected-strings stable and avoid minute-rollover races, each case asserts
# the ts segment is present and well-formed via grep, then strips it before
# comparing to the pre-ts expected line. Issue #363.
assert_ts() {
  local out="$1" case_name="$2"
  echo "$out" | grep -qE 'ts [0-2][0-9]:[0-5][0-9]' \
    || fail "$case_name — ts HH:MM segment missing or malformed" "$out"
}
strip_ts() {
  # Remove either "  |  ts HH:MM" (interior position, typical case) or
  # "ts HH:MM  |  " (leading position, when model segment is omitted).
  sed -E 's/  \|  ts [0-2][0-9]:[0-5][0-9]//; s/^ts [0-2][0-9]:[0-5][0-9]  \|  //'
}

# Build a fixture project at a known path with a known branch. We
# initialize a git repo so the hook's `git rev-parse --abbrev-ref HEAD`
# call resolves to the branch we choose. The fixture also stubs
# scripts/refresh-stage-cache.sh so the hook's background refresh is a
# no-op (we provide the cache file directly when needed).
new_fixture() {
  local name="$1" branch="${2:-main}"
  local fix="$ROOT_TMP/$name"
  mkdir -p "$fix/.claude/hooks" "$fix/scripts/lib" "$fix/.arboretum"
  cp "$REPO_ROOT/.claude/hooks/statusline.sh" "$fix/.claude/hooks/"
  cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-stage-cache.sh"
  chmod +x "$fix/scripts/refresh-stage-cache.sh"
  # `git init -b` is git 2.28+; use init + checkout for portability,
  # matching the convention in the other smoke tests.
  git -C "$fix" init -q
  git -C "$fix" config user.email f@e.com
  git -C "$fix" config user.name f
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m seed
  git -C "$fix" checkout -q -b "$branch" 2>/dev/null || git -C "$fix" branch -m "$branch"
  echo "$fix"
}

run_hook() {
  local fix="$1" stdin="$2"
  printf '%s' "$stdin" | CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/statusline.sh"
}

# ── Case 1: full line — all segments present ─────────────────────────
fix=$(new_fixture proj_full ember-thrush)
cat > "$fix/.arboretum/active-stage-cache.json" <<'JSON'
{"issue": 307, "stage": "/build", "ts": "2026-05-23T14:05:00Z"}
JSON
input='{"model":{"display_name":"Opus 4.7"},"workspace":{"project_dir":"'$fix'","git_worktree":"ember-thrush"},"context_window":{"used_percentage":42.7},"rate_limits":{"five_hour":{"used_percentage":24.5},"seven_day":{"used_percentage":27.1}}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 1"
stripped=$(printf '%s' "$out" | strip_ts)
expected="Opus 4.7  |  proj_full/ember-thrush  |  ctx 42%  |  5h:24% 7d:27%  |  wt:ember-thrush  |  [#307 /build]"
[ "$stripped" = "$expected" ] || fail "case 1 — full line shape" "got:      $stripped
expected: $expected"
ok "case 1 — full line shape with all segments (ts asserted + stripped)"

# ── Case 1b: issue title appended to the chip (#763, user-only) ──────
# The statusline is a user-only surface — the model never ingests it — so the
# author-controlled issue title is safe to render here (unlike the model-facing
# SessionStart banner, which now renders only the bare issue number).
fix=$(new_fixture proj_title ember-thrush)
cat > "$fix/.arboretum/active-stage-cache.json" <<'JSON'
{"issue": 307, "stage": "/build", "title": "Reframe idea capture", "ts": "2026-05-23T14:05:00Z"}
JSON
input='{"model":{"display_name":"Opus 4.7"},"workspace":{"project_dir":"'$fix'","git_worktree":"ember-thrush"},"context_window":{"used_percentage":42.7},"rate_limits":{"five_hour":{"used_percentage":24.5},"seven_day":{"used_percentage":27.1}}}'
out=$(run_hook "$fix" "$input")
stripped=$(printf '%s' "$out" | strip_ts)
expected="Opus 4.7  |  proj_title/ember-thrush  |  ctx 42%  |  5h:24% 7d:27%  |  wt:ember-thrush  |  [#307 /build] Reframe idea capture"
[ "$stripped" = "$expected" ] || fail "case 1b — chip with title" "got:      $stripped
expected: $expected"
ok "case 1b — issue title appended to the statusline chip (#763)"

# ── Case 1c: title control-char scrubbed + long title truncated ──────
fix=$(new_fixture proj_longtitle main)
python3 -c "
import json
# ESC early so the scrub (not truncation) is what removes it; long enough to
# exercise the truncation cap.
d = {'issue': 42, 'stage': '/design',
     'title': chr(27)+'[31mThis title is definitely longer than forty chars total',
     'ts': '2026-05-23T14:05:00Z'}
print(json.dumps(d))
" > "$fix/.arboretum/active-stage-cache.json"
input='{"model":{"display_name":"Opus 4.7"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":8}}'
out=$(run_hook "$fix" "$input")
printf '%s' "$out" | python3 -c "import sys; sys.exit(0 if b'\x1b' in sys.stdin.buffer.read() else 1)" \
  && fail "case 1c — raw ESC survived into statusline title (scrub failed)" "$out"
stripped=$(printf '%s' "$out" | strip_ts)
echo "$stripped" | grep -q '\[#42 /design\] \[31mThis title' \
  || fail "case 1c — expected scrubbed title prefix in chip" "$stripped"
echo "$stripped" | grep -q '…' \
  || fail "case 1c — expected ellipsis on truncated long title" "$stripped"
ok "case 1c — title ESC-scrubbed and long title truncated with ellipsis"

# ── Case 2: chip omitted when cache absent ───────────────────────────
fix=$(new_fixture proj_nochip main)
input='{"model":{"display_name":"Opus 4.7"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":8}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 2"
stripped=$(printf '%s' "$out" | strip_ts)
echo "$stripped" | grep -q '\[#' && fail "case 2 — chip should be absent without cache" "$out"
[ "$stripped" = "Opus 4.7  |  proj_nochip/main  |  ctx 8%" ] \
  || fail "case 2 — line shape without chip" "got: $stripped"
ok "case 2 — chip omitted when active-stage-cache absent"

# ── Case 3: 5h/7d segment omitted when either window absent ──────────
fix=$(new_fixture proj_partial_rl main)
input='{"model":{"display_name":"M"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":50},"rate_limits":{"five_hour":{"used_percentage":24}}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 3"
stripped=$(printf '%s' "$out" | strip_ts)
echo "$stripped" | grep -qE '5h:|7d:' \
  && fail "case 3 — 5h:/7d: segment must be all-or-nothing" "$out"
[ "$stripped" = "M  |  proj_partial_rl/main  |  ctx 50%" ] \
  || fail "case 3 — line shape with partial rate-limit data" "got: $stripped"
ok "case 3 — 5h:/7d: segment omitted when either window absent"

# ── Case 4: ctx segment omitted when used_percentage is null ─────────
fix=$(new_fixture proj_noctxseg main)
input='{"model":{"display_name":"M"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":null}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 4"
stripped=$(printf '%s' "$out" | strip_ts)
echo "$stripped" | grep -qE '(^|\| )ctx [0-9]' \
  && fail "case 4 — ctx segment should be absent when null" "$out"
[ "$stripped" = "M  |  proj_noctxseg/main" ] \
  || fail "case 4 — line shape without ctx" "got: $stripped"
ok "case 4 — ctx segment omitted when context_window.used_percentage is null"

# ── Case 5: wt: segment omitted in main worktree (no git_worktree) ───
fix=$(new_fixture proj_mainwt main)
input='{"model":{"display_name":"M"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":10}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 5"
echo "$out" | grep -q 'wt:' && fail "case 5 — wt: should be absent in main worktree" "$out"
ok "case 5 — wt: segment omitted in main worktree"

# ── Case 6: control characters scrubbed (defense in depth) ───────────
fix=$(new_fixture proj_scrub main)
# Build the input via python so we get real ESC (0x1b) bytes, not
# literal backslash-escape sequences. The branch can't easily carry
# control chars (git rejects them), so we test model + git_worktree.
input=$(python3 -c 'import json; print(json.dumps({"model":{"display_name":"Opus\x1b[31mEVIL\x1b[0m"},"workspace":{"project_dir":"'"$fix"'","git_worktree":"wt\x1b[5mBLINK\x1b[0m"},"context_window":{"used_percentage":1}}))')
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 6"
# After scrubbing, the ESC bytes (0x1b) are gone; the literal brackets
# and letters remain visible but harmless.
echo "$out" | LC_ALL=C grep -q $'\x1b' \
  && fail "case 6 — ESC byte must be scrubbed from output" "$(printf '%s' "$out" | od -c | head)"
# Confirm the harmless residue around the scrubbed control bytes is
# still rendered (proves scrub, not drop) — the [31m / [0m / [5m
# literals remain because their `[`, digits, `m` are printable chars.
echo "$out" | grep -q 'Opus\[31mEVIL\[0m' \
  || fail "case 6 — scrubbed model should preserve printable residue" "$out"
echo "$out" | grep -q 'wt:wt\[5mBLINK\[0m' \
  || fail "case 6 — scrubbed worktree should preserve printable residue" "$out"
ok "case 6 — control characters scrubbed from string fields"

# ── Case 7: ts segment present and well-formed regardless of populated
#           segments (issue #363) ───────────────────────────────────────
# Sub-case 7a: with a full payload, ts must appear immediately after the
# model segment (the documented stable position).
fix=$(new_fixture proj_ts_full main)
input='{"model":{"display_name":"M"},"workspace":{"project_dir":"'$fix'"},"context_window":{"used_percentage":1}}'
out=$(run_hook "$fix" "$input")
assert_ts "$out" "case 7a"
echo "$out" | grep -qE '^M  \|  ts [0-2][0-9]:[0-5][0-9]  \|  ' \
  || fail "case 7a — ts must appear immediately after model" "$out"
ok "case 7a — ts positioned immediately after model"

# Sub-case 7b: when stdin is empty (no model), ts becomes the leading
# segment — confirms the always-present invariant.
fix=$(new_fixture proj_ts_nomodel main)
out=$(run_hook "$fix" "")
assert_ts "$out" "case 7b"
echo "$out" | grep -qE '^ts [0-2][0-9]:[0-5][0-9]  \|  ' \
  || fail "case 7b — ts must lead when model segment absent" "$out"
ok "case 7b — ts leads when model segment absent"

echo
echo "statusline smoke tests passed."
exit 0
