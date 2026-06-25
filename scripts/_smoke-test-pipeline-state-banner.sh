#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# _smoke-test-pipeline-state-banner.sh — Verify session-start.sh surfaces
# the WS9 pipeline-state lines: Stage, Last action, Last session (D7).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

new_fixture() {
  local fix="$ROOT_TMP/$1"
  mkdir -p "$fix/docs/definitions" "$fix/.claude/hooks" "$fix/scripts" "$fix/.arboretum"
  echo "# x" > "$fix/docs/ARCHITECTURE.md"
  echo "# x" > "$fix/docs/REGISTER.md"
  echo "# x" > "$fix/contracts.yaml"
  echo "layer: 0" > "$fix/.arboretum.yml"
  cp "$REPO_ROOT/.claude/hooks/session-start.sh" "$fix/.claude/hooks/"
  mkdir -p "$fix/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/scrub-control-chars.sh" "$fix/scripts/lib/"
  # Stub refresh-next-cache.sh + refresh-stage-cache.sh to no-ops.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-next-cache.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/refresh-stage-cache.sh"
  chmod +x "$fix/scripts/"*.sh
  git -C "$fix" init -q
  git -C "$fix" config user.email f@e.com; git -C "$fix" config user.name f
  git -C "$fix" config commit.gpgsign false
  git -C "$fix" commit -q --allow-empty -m seed
  echo "$fix"
}

# ── Case 1: stage cache + log comments → 3 pipeline-state lines ──────
fix=$(new_fixture case1)
cat > "$fix/.arboretum/next-cache.json" <<'JSON'
{ "fetched_at": "2026-05-23T14:00:00Z",
  "issue": { "number": 307, "title": "WS9 build", "url": "u",
             "body_first_lines": [], "body_empty": false,
             "labels": ["next-up"], "updated_at": "2026-05-23T14:00:00Z" },
  "handoff": null, "no_gh_remote": false, "error": null }
JSON
cat > "$fix/.arboretum/active-stage-cache.json" <<'JSON'
{ "issue": 307, "stage": "/build", "ts": "2026-05-23T14:05:00Z" }
JSON
cat > "$fix/.arboretum/log-comments-cache.json" <<'JSON'
[
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-22T17:20:00Z — /design exited, plan: docs/plan.md, next: /build", "createdAt":"2026-05-22T17:20:00Z"},
  {"body":"<!-- pipeline-state:log -->\n- 2026-05-22T17:35:00Z — /handoff summary, summary: \"Drafted WS9 plan; ready for build\"", "createdAt":"2026-05-22T17:35:00Z"}
]
JSON

out=$(CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" 2>&1)
echo "$out" | grep -qE 'Stage:.*/build' \
  || fail "case 1 — expected 'Stage: /build' line" "$out"
echo "$out" | grep -qE 'Last action:.*/design exited' \
  || fail "case 1 — expected 'Last action:' line with /design exited" "$out"
echo "$out" | grep -qE 'Last session:.*WS9 plan' \
  || fail "case 1 — expected 'Last session:' summary line" "$out"
ok "case 1 — banner surfaces Stage / Last action / Last session"

# ── Case 2: no stage cache → banner omits pipeline-state lines ───────
fix=$(new_fixture case2)
out=$(CLAUDE_PROJECT_DIR="$fix" bash "$fix/.claude/hooks/session-start.sh" 2>&1)
echo "$out" | grep -qE '^Stage:' \
  && fail "case 2 — banner should not render 'Stage:' line without cache" "$out"
ok "case 2 — banner gracefully omits lines when no cache"

echo; echo "pipeline-state-banner smoke tests passed."
exit 0
