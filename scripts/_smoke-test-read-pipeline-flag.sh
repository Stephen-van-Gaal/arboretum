#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
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

# Case 1: explicit current general-release pipeline
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: unified
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 1 - explicit unified" "got: $out"
ok "case 1 - explicit unified reads correctly"

# Case 2: missing pipeline block defaults to current general-release
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
profile: lean
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 2 - missing pipeline block defaults to unified" "got: $out"
ok "case 2 - missing pipeline block defaults to unified"

# Case 3: retired v1 fails closed
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v1
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>"$ROOT_TMP/retired.err"); then
  fail "case 3 - retired v1 should fail closed" "got: $(cd "$ROOT_TMP" && bash "$READ" 2>&1)"
fi
grep -q "retired" "$ROOT_TMP/retired.err" \
  || fail "case 3 - retired v1 diagnostic should mention retired" "$(cat "$ROOT_TMP/retired.err")"
ok "case 3 - retired v1 fails closed"

# Case 4: retired v2 fails closed
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: v2
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>"$ROOT_TMP/retired.err"); then
  fail "case 4 - retired v2 should fail closed" "got: $(cd "$ROOT_TMP" && bash "$READ" 2>&1)"
fi
grep -q "retired" "$ROOT_TMP/retired.err" \
  || fail "case 4 - retired v2 diagnostic should mention retired" "$(cat "$ROOT_TMP/retired.err")"
ok "case 4 - retired v2 fails closed"

# Case 5: unknown value exits 1 with diagnostic
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: experimental
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>"$ROOT_TMP/unknown.err"); then
  fail "case 5 - unknown value" "expected exit 1, got exit 0"
fi
grep -q "unknown pipeline.workflow value" "$ROOT_TMP/unknown.err" \
  || fail "case 5 - unknown diagnostic" "$(cat "$ROOT_TMP/unknown.err")"
ok "case 5 - unknown value exits non-zero"

# Case 6: double-quoted value → accepted (YAML-legal alternative form)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: "unified"
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 6 — double-quoted unified" "got: $out"
ok "case 6 — double-quoted value accepted"

# Case 7: single-quoted value → accepted
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: 'unified'
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 7 — single-quoted unified" "got: $out"
ok "case 7 — single-quoted value accepted"

# Case 8: value with trailing inline comment → comment stripped, value accepted
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: unified  # current general-release pipeline
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 8 — trailing comment" "got: $out"
ok "case 8 — trailing inline comment stripped"

# Case 9: trailing comment on the pipeline: line itself
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:  # WS2 of pipeline-overhaul
  workflow: unified
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 9 — comment on pipeline: line" "got: $out"
ok "case 9 — comment on block-header line tolerated"

# Case 10: YAML flow-style mapping → accepted (codex P2: previously
# silently defaulted to v1 because awk only matched block style)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline: { workflow: unified }
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 10 — flow-style mapping" "got: $out"
ok "case 10 — flow-style mapping accepted"

# Case 11: # inside a quoted value → kept, value passes through quoting
# (codex P2: previously, awk stripped # before quote handling, so
# "unified#junk" could become "unified" and falsely validate as valid)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: "unified#junk"
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>"$ROOT_TMP/hash.err"); then
  fail "case 11 — '#' inside quoted value should reject 'unified#junk' as invalid" "got: $(cd "$ROOT_TMP" && bash "$READ" 2>&1)"
fi
grep -q "unknown pipeline.workflow value" "$ROOT_TMP/hash.err" \
  || fail "case 11 — quoted hash diagnostic" "$(cat "$ROOT_TMP/hash.err")"
ok "case 11 — # inside quoted value preserved; invalid value rejected"

# Case 12: nested workflow under pipeline.options is NOT pipeline.workflow
# (codex P2: previously awk matched any indented workflow: under pipeline,
# so nested keys could silently flip routing)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  options:
    workflow: unified
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 12 — nested pipeline.options.workflow should NOT be read as pipeline.workflow" "got: $out"
ok "case 12 — nested workflow key ignored; defaults to unified"

# Case 13: quoted top-level key after pipeline: block — block scope ends
# properly (codex P2: previously awk's [a-zA-Z] guard missed quoted keys)
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: unified
'other-key':
  workflow: v1
YAML
out=$(cd "$ROOT_TMP" && bash "$READ")
[ "$out" = "unified" ] || fail "case 13 — pipeline block ends at quoted next key" "got: $out"
ok "case 13 — quoted top-level key closes pipeline scope correctly"

# Case 14: malformed YAML → exits 1 with parser error
cat > "$ROOT_TMP/roadmap.config.yaml" <<'YAML'
pipeline:
  workflow: unified
  : malformed
   bad indent
YAML
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 14 — malformed YAML should exit non-zero"
fi
ok "case 14 — malformed YAML rejected"

# Case 15: missing config file → exits 1 with diagnostic
rm -f "$ROOT_TMP/roadmap.config.yaml"
if (cd "$ROOT_TMP" && bash "$READ" 2>/dev/null); then
  fail "case 15 — missing config" "expected exit 1, got exit 0"
fi
ok "case 15 — missing config exits non-zero"

echo "ALL PASS: read-pipeline-flag.sh"
