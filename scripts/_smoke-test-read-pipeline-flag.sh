#!/usr/bin/env bash
# owner: workflow-unification
# _smoke-test-read-pipeline-flag.sh — Verify the pipeline.workflow flag reader.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

READ="$REPO_ROOT/scripts/read-pipeline-flag.sh"

# Case 1: v1 explicit — config present, workflow: v1
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v1
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v1" ] || fail "case 1 — v1 explicit" "got: $out"
ok "case 1 — v1 explicit reads correctly"

# Case 2: v2 override
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v2
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 2 — v2 override" "got: $out"
ok "case 2 — v2 override reads correctly"

# Case 3: missing pipeline block → defaults to v1 (back-compat)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
profile: lean
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v1" ] || fail "case 3 — missing pipeline block defaults to v1" "got: $out"
ok "case 3 — missing pipeline block defaults to v1"

# Case 4: missing config file → exits 1 with diagnostic
rm -f "$ROOT_TMP/roadmap.config.yaml"
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 4 — missing config" "expected exit 1, got exit 0"
fi
ok "case 4 — missing config exits non-zero"

# Case 5: invalid value → exits 1
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: vBOGUS
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 5 — invalid value" "expected exit 1, got exit 0"
fi
ok "case 5 — invalid value exits non-zero"

# Case 6: double-quoted value → accepted (YAML-legal alternative form)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: "v2"
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 6 — double-quoted v2" "got: $out"
ok "case 6 — double-quoted value accepted"

# Case 7: single-quoted value → accepted
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: 'v1'
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v1" ] || fail "case 7 — single-quoted v1" "got: $out"
ok "case 7 — single-quoted value accepted"

# Case 8: value with trailing inline comment → comment stripped, value accepted
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v2  # opt-in for the new agent-target lane
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 8 — trailing comment" "got: $out"
ok "case 8 — trailing inline comment stripped"

# Case 9: trailing comment on the pipeline: line itself
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:  # WS2 of pipeline-overhaul
  workflow: v2
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 9 — comment on pipeline: line" "got: $out"
ok "case 9 — comment on block-header line tolerated"

# Case 10: YAML flow-style mapping → accepted (codex P2: previously
# silently defaulted to v1 because awk only matched block style)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline: { workflow: v2 }
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 10 — flow-style mapping" "got: $out"
ok "case 10 — flow-style mapping accepted"

# Case 11: # inside a quoted value → kept, value passes through quoting
# (codex P2: previously, awk stripped # before quote handling, so
# "v2#junk" became "v2" and falsely validated as valid)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: "v2#junk"
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 11 — '#' inside quoted value should reject 'v2#junk' as invalid" "got: $(cd "$ROOT_TMP" && bash "$READ" 2>&1)"
fi
ok "case 11 — # inside quoted value preserved; invalid value rejected"

# Case 12: nested workflow under pipeline.options is NOT pipeline.workflow
# (codex P2: previously awk matched any indented workflow: under pipeline,
# so nested keys could silently flip routing)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  options:
    workflow: v2
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v1" ] || fail "case 12 — nested pipeline.options.workflow should NOT be read as pipeline.workflow" "got: $out"
ok "case 12 — nested workflow key ignored; defaults to v1"

# Case 13: quoted top-level key after pipeline: block — block scope ends
# properly (codex P2: previously awk's [a-zA-Z] guard missed quoted keys)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v2
'other-key':
  workflow: v1
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "v2" ] || fail "case 13 — pipeline block ends at quoted next key" "got: $out"
ok "case 13 — quoted top-level key closes pipeline scope correctly"

# Case 14: malformed YAML → exits 1 with parser error
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v2
  : malformed
   bad indent
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 14 — malformed YAML should exit non-zero"
fi
ok "case 14 — malformed YAML rejected"

echo "ALL PASS: read-pipeline-flag.sh"
