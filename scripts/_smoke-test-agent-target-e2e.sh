#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# _smoke-test-agent-target-e2e.sh — End-to-end smoke test of the agent-target
# pipeline at the shell-seam layer: flag is unified, brief is written, /build's
# S2 helper accepts the brief, all five required S2 fields parse correctly.
# Markdown-skill behaviour (/start prose, /build dispatch) is verified by
# manual walk-through, not here.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

cd "$ROOT_TMP"

# Seed a minimal repo-shaped config in the temp dir
cat > roadmap.config.yaml <<'YAML'
pipeline:
  workflow: unified
YAML

# Seam 1: read-pipeline-flag.sh returns unified
FLAG=$(bash "$REPO_ROOT/scripts/read-pipeline-flag.sh")
[ "$FLAG" = "unified" ] || fail "seam 1 — flag read" "got: $FLAG"
ok "seam 1 — pipeline flag reads unified"

# Seam 2: write-agent-brief.sh produces a brief
echo "Rename foo to bar in baz.sh" | bash "$REPO_ROOT/scripts/write-agent-brief.sh" 12345 >/dev/null
BRIEF=".arboretum/agent-briefs/12345.md"
[ -f "$BRIEF" ] || fail "seam 2 — brief not written"
ok "seam 2 — agent-brief written for #12345"

# Seam 3: read-s2-frontmatter.sh accepts the brief (the contract /build enforces)
out=$(bash "$REPO_ROOT/scripts/read-s2-frontmatter.sh" "$BRIEF")
grep -q "^related-issue=12345" <<<"$out" || fail "seam 3 — related-issue not parsed" "$out"
grep -q "^triage=agent-target" <<<"$out" || fail "seam 3 — triage not parsed" "$out"
grep -q "^implementation-mode=direct" <<<"$out" || fail "seam 3 — mode not parsed" "$out"
grep -q "^plan=null" <<<"$out" || fail "seam 3 — plan not parsed" "$out"
ok "seam 3 — /build's S2 reader accepts the brief"

# Seam 4: every required field /build expects is present (whole-schema gate)
for field in related-issue test-tiers implementation-mode triage plan; do
  grep -qE "^${field}(\\.|=)" <<<"$out" || fail "seam 4 — missing field: $field" "$out"
done
ok "seam 4 — all five S2 required fields present in brief frontmatter"

echo "ALL PASS: agent-target end-to-end"
