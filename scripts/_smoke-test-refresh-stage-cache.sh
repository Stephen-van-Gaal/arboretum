#!/usr/bin/env bash
# owner: pipeline-state-tracking
# _smoke-test-refresh-stage-cache.sh — Verify scripts/refresh-stage-cache.sh
# per WS9 design D6 (active-issue resolution + 30s-TTL cache shape).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REFRESH="$REPO_ROOT/scripts/refresh-stage-cache.sh"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

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
  "api repos/{owner}/{repo}")
    printf 'owner/repo\n'
    exit 0 ;;
  "issue view")
    # Stage now lives in a stage:* label. refresh-stage-cache.sh reads it via
    # --json labels --jq '.labels[].name', so honor that by printing the
    # fixture label set (newline-separated names) from $GH_STUB_LABELS.
    case "$*" in
      # #767: refresh-stage-cache.sh now fetches labels + title in ONE
      # `--json labels,title` call (no --jq). Emulate gh by emitting a JSON
      # object built from the fixture label set ($GH_STUB_LABELS, whitespace-
      # separated) and title ($GH_STUB_TITLE, preserved verbatim incl. ESC).
      *--json\ labels,title*|*--json\ labels*)
        python3 -c "
import json, os
names = (os.environ.get('GH_STUB_LABELS') or '').split()
title = os.environ.get('GH_STUB_TITLE') or ''
print(json.dumps({'labels': [{'name': n} for n in names], 'title': title}))
"
        exit 0 ;;
    esac
    cat "${GH_STUB_BODY:-/dev/null}" 2>/dev/null \
      || echo '{"body":"## Context","number":307,"title":"WS9"}'
    exit 0 ;;
  "issue list")
    cat "${GH_STUB_ISSUES:-/dev/null}" 2>/dev/null || echo '[]'
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$bindir/gh"
  echo "$bindir"
}

# ── Case 1: branch matches a design spec → that issue is active ──────
c1=$(new_repo case1)
bindir=$(install_gh_stub "$c1")
git -C "$c1" checkout -q -b feat/foo-bar-build
cat > "$c1/docs/superpowers/specs/2026-05-23-foo-bar-design.md" <<'SPEC'
---
related-issue: 999
---
# foo-bar
SPEC
# #763: the active issue's title is fetched for the statusline and stored,
# control-char scrubbed. Inject a raw ESC to verify the scrub.
GH_STUB_LABELS="stage:build agent-ready" GH_STUB_TITLE=$'Wire the seam\x1b[31mX' \
  PATH="$bindir:$PATH" bash "$REFRESH" "$c1"
cache="$c1/.arboretum/active-stage-cache.json"
[ -f "$cache" ] || fail "case 1 — cache not written"
python3 -c "
import json,sys
c = json.load(open(sys.argv[1]))
assert c['issue'] == 999, c
assert c['stage'] == '/build', c
assert 'ts' in c, c
# #763: title present, control-char scrubbed (ESC stripped, residue kept).
assert c.get('title') == 'Wire the seam[31mX', c
assert '\x1b' not in (c.get('title') or ''), c
" "$cache" || fail "case 1 — cache shape wrong" "$(cat "$cache")"
ok "case 1 — branch-matched design spec resolves to that issue; title cached + scrubbed"

# ── Case 2: no branch match → falls back to next-up ──────────────────
c2=$(new_repo case2)
bindir=$(install_gh_stub "$c2")
cat > "$c2/issues.json" <<'JSON'
[{"number":555,"title":"next-up issue"}]
JSON
GH_STUB_ISSUES="$c2/issues.json" GH_STUB_LABELS="stage:design" \
  PATH="$bindir:$PATH" bash "$REFRESH" "$c2"
cache="$c2/.arboretum/active-stage-cache.json"
python3 -c "
import json,sys
c = json.load(open(sys.argv[1]))
assert c['issue'] == 555, c
assert c['stage'] == '/design', c
" "$cache" || fail "case 2 — next-up fallback wrong" "$(cat "$cache")"
ok "case 2 — falls back to next-up when no branch match"

# ── Case 3: no branch match AND no next-up → cache has issue:null ────
c3=$(new_repo case3)
bindir=$(install_gh_stub "$c3")
echo '[]' > "$c3/issues.json"
GH_STUB_ISSUES="$c3/issues.json" PATH="$bindir:$PATH" bash "$REFRESH" "$c3"
python3 -c "
import json,sys
c = json.load(open(sys.argv[1]))
assert c.get('issue') is None, c
" "$c3/.arboretum/active-stage-cache.json" \
  || fail "case 3 — expected issue:null when no active issue" \
       "$(cat "$c3/.arboretum/active-stage-cache.json")"
ok "case 3 — issue:null when no resolution path succeeds"

# ── Case 4: no stage:* label → stage is null ─────────────────────────
c4=$(new_repo case4)
bindir=$(install_gh_stub "$c4")
git -C "$c4" checkout -q -b feat/no-stage-build
cat > "$c4/docs/superpowers/specs/2026-05-23-no-stage-design.md" <<'SPEC'
---
related-issue: 111
---
SPEC
GH_STUB_LABELS="agent-ready" PATH="$bindir:$PATH" bash "$REFRESH" "$c4"
python3 -c "
import json,sys
c = json.load(open(sys.argv[1]))
assert c['issue'] == 111, c
assert c.get('stage') is None, c
" "$c4/.arboretum/active-stage-cache.json" \
  || fail "case 4 — stage should be null when no stage:* label present" \
       "$(cat "$c4/.arboretum/active-stage-cache.json")"
ok "case 4 — stage is null when no stage:* label present"

# ── Case 5: log-comments-cache filters to pipeline-state:log markers ──
# The stage cache is well-covered; this case asserts the SECOND cache
# (log-comments-cache.json) is written, contains only comments carrying
# the `<!-- pipeline-state:log -->` marker, and preserves their body +
# createdAt. The gh stub's `gh api .../comments` arm currently returns
# `[]` via its catch-all; extend the stub here to return mixed comments.
c5=$(new_repo case5)
bindir5="$c5/.bin"; mkdir -p "$bindir5"
cat > "$bindir5/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "api repos/{owner}/{repo}")
    printf 'owner/repo\n'
    exit 0 ;;
  "issue view")
    cat "${GH_STUB_BODY:-/dev/null}" 2>/dev/null \
      || echo '{"body":"","number":0,"title":""}'
    exit 0 ;;
  "issue list")
    cat "${GH_STUB_ISSUES:-/dev/null}" 2>/dev/null || echo '[]'
    exit 0 ;;
  "api "*)
    cat "${GH_STUB_COMMENTS:-/dev/null}" 2>/dev/null || echo '[]'
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$bindir5/gh"
git -C "$c5" checkout -q -b feat/foo-bar-build
cat > "$c5/docs/superpowers/specs/2026-05-23-foo-bar-design.md" <<'SPEC'
---
related-issue: 777
---
SPEC
echo '{"body":"## just a body","number":777,"title":"foo-bar"}' > "$c5/body.json"
cat > "$c5/comments.json" <<'JSON'
[
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-23T14:03:00Z — /design entered, branch: feat/foo-bar", "created_at":"2026-05-23T14:03:00Z"},
  {"body":"A normal non-pipeline comment from a human reviewer.", "created_at":"2026-05-23T14:10:00Z"},
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-23T14:20:00Z — /handoff summary, summary: \"drafted plan\"", "created_at":"2026-05-23T14:20:00Z"},
  {"body":"<!-- arbo-handoff: feat/foo-bar 2026-05-23T14:25:00Z -->\nUnrelated handoff comment.", "created_at":"2026-05-23T14:25:00Z"}
]
JSON
GH_STUB_BODY="$c5/body.json" GH_STUB_COMMENTS="$c5/comments.json" \
  PATH="$bindir5:$PATH" bash "$REFRESH" "$c5"

log_cache="$c5/.arboretum/log-comments-cache.json"
[ -f "$log_cache" ] || fail "case 5 — log-comments-cache.json not written"
python3 -c "
import json, sys
out = json.load(open(sys.argv[1]))
assert isinstance(out, list), f'expected list, got {type(out)}'
assert len(out) == 2, f'expected exactly 2 filtered comments, got {len(out)}: {out}'
for c in out:
    assert '<!-- pipeline-state:log -->' in c.get('body',''), f'non-pipeline-state comment leaked through: {c}'
    assert c.get('createdAt'), f'createdAt missing or empty: {c}'
# Order: writer preserves source order. First pipeline-state entry is the entered line.
assert '/design entered' in out[0]['body'], f'first entry wrong: {out[0]}'
assert '/handoff summary' in out[1]['body'], f'second entry wrong: {out[1]}'
" "$log_cache" \
  || fail "case 5 — log-comments-cache filtering wrong" \
       "$(cat "$log_cache")"
ok "case 5 — log-comments-cache filters to pipeline-state:log marker only"

echo
echo "refresh-stage-cache smoke tests passed."
exit 0
