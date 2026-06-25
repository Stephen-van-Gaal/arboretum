#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# Contract test for docs/contracts/validate-template-taxonomy.cli-contract.md.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-template-taxonomy.sh"
BASH_BIN="$(command -v bash)"
ERR=$(mktemp)
OUT=$(mktemp)
TMP=$(mktemp -d)
trap 'rm -f "$ERR" "$OUT"; rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }
  fail=1
}

write_template() {
  local path="$1"
  local shape="$2"
  local body="$3"
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    echo "document-shape: $shape"
    echo "---"
    printf '%s\n' "$body"
  } > "$path"
}

write_catalog() {
  local path="$1"
  local template_path="$2"
  cat > "$path" <<EOF
document_shapes:
  fixture:
    template: $template_path
    description: Fixture shape.
    sections:
      - key: purpose
        heading: Purpose
        content: Purpose text.
        required: yes
      - key: behaviour
        heading: Behaviour
        content: Behaviour text.
        required: yes
        aliases:
          - Current Behaviour
EOF
}

fixture_rel() {
  python3 - "$ROOT" "$1" <<'PY'
import os
import sys
print(os.path.relpath(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[1])))
PY
}

run_validator() {
  : > "$OUT"
  : > "$ERR"
  bash "$VALIDATOR" "$@" >"$OUT" 2>"$ERR"
}

run_validator_without_python() {
  local fake_bin="$TMP/no-python-bin"
  mkdir -p "$fake_bin"
  ln -sf "$(command -v dirname)" "$fake_bin/dirname"
  ln -sf "$(command -v mktemp)" "$fake_bin/mktemp"
  ln -sf "$(command -v rm)" "$fake_bin/rm"
  ln -sf "$(command -v sed)" "$fake_bin/sed"
  ln -sf "$BASH_BIN" "$fake_bin/bash"
  : > "$OUT"
  : > "$ERR"
  PATH="$fake_bin" "$BASH_BIN" "$VALIDATOR" "$@" >"$OUT" 2>"$ERR"
}

# VTT-1 — real catalog validates with no hard failures.
run_validator
rc=$?
if [ "$rc" = 0 ] && [ ! -s "$OUT" ] && grep -q "TEMPLATE-TAXONOMY-SUMMARY:" "$ERR"; then
  pass VTT-1
else
  fail_case VTT-1 "rc=$rc out=$(cat "$OUT") err=$(cat "$ERR")"
fi

# VTT-2 — missing template path is a hard failure.
missing_catalog="$TMP/missing-template.yaml"
write_catalog "$missing_catalog" "$(fixture_rel "$TMP/missing-template.md")"
run_validator "$missing_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "missing-template" "$ERR"; then
  pass VTT-2
else
  fail_case VTT-2 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-3 — mismatched document-shape is a hard failure.
wrong_shape_template="$TMP/wrong-shape.md"
wrong_shape_catalog="$TMP/wrong-shape.yaml"
write_template "$wrong_shape_template" "wrong-shape" $'# Fixture\n\n## Purpose\n\nText.\n\n## Behaviour\n\nText.'
write_catalog "$wrong_shape_catalog" "$(fixture_rel "$wrong_shape_template")"
run_validator "$wrong_shape_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "document-shape" "$ERR"; then
  pass VTT-3
else
  fail_case VTT-3 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-4 — missing required section is a hard failure.
missing_required_template="$TMP/missing-required.md"
missing_required_catalog="$TMP/missing-required.yaml"
write_template "$missing_required_template" "fixture" $'# Fixture\n\n## Purpose\n\nText.'
write_catalog "$missing_required_catalog" "$(fixture_rel "$missing_required_template")"
run_validator "$missing_required_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "key=behaviour" "$ERR"; then
  pass VTT-4
else
  fail_case VTT-4 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-5 — duplicate semantic heading match is a hard failure.
duplicate_template="$TMP/duplicate.md"
duplicate_catalog="$TMP/duplicate.yaml"
write_template "$duplicate_template" "fixture" $'# Fixture\n\n## Purpose\n\nText.\n\n## Behaviour\n\nText.\n\n## Behaviour\n\nAgain.'
write_catalog "$duplicate_catalog" "$(fixture_rel "$duplicate_template")"
run_validator "$duplicate_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "duplicate" "$ERR"; then
  pass VTT-5
else
  fail_case VTT-5 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-6 — alias-backed rename is lifecycle-required, not a hard failure.
alias_template="$TMP/alias.md"
alias_catalog="$TMP/alias.yaml"
write_template "$alias_template" "fixture" $'# Fixture\n\n## Purpose\n\nText.\n\n## Current Behaviour\n\nText.'
write_catalog "$alias_catalog" "$(fixture_rel "$alias_template")"
run_validator "$alias_catalog"
rc=$?
if [ "$rc" = 0 ] && grep -q "lifecycle-required" "$ERR" && grep -q "key=behaviour" "$ERR"; then
  pass VTT-6
else
  fail_case VTT-6 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-7 — extra provider guidance heading warns but exits 0.
extra_heading_template="$TMP/extra-heading.md"
extra_heading_catalog="$TMP/extra-heading.yaml"
write_template "$extra_heading_template" "fixture" $'# Fixture\n\n## Purpose\n\nText.\n\n## Behaviour\n\nText.\n\n## Provider Notes\n\nExtra guidance.'
write_catalog "$extra_heading_catalog" "$(fixture_rel "$extra_heading_template")"
run_validator "$extra_heading_catalog"
rc=$?
if [ "$rc" = 0 ] && grep -q "warning" "$ERR" && grep -q "Provider Notes" "$ERR"; then
  pass VTT-7
else
  fail_case VTT-7 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-8 — wrong argument count is invocation error.
run_validator "$extra_heading_catalog" "$extra_heading_catalog"
rc=$?
if [ "$rc" = 2 ] && grep -q "Usage:" "$ERR"; then
  pass VTT-8
else
  fail_case VTT-8 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-9 — missing python3 is a setup error with a setup diagnostic.
run_validator_without_python "$extra_heading_catalog"
rc=$?
if [ "$rc" = 2 ] && grep -q "python3 not found" "$ERR"; then
  pass VTT-9
else
  fail_case VTT-9 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-10 — one template heading cannot satisfy two catalog sections.
reused_heading_template="$TMP/reused-heading.md"
reused_heading_catalog="$TMP/reused-heading.yaml"
write_template "$reused_heading_template" "fixture" $'# Fixture\n\n## Behaviour\n\nText.'
cat > "$reused_heading_catalog" <<EOF
document_shapes:
  fixture:
    template: $(fixture_rel "$reused_heading_template")
    description: Fixture shape.
    sections:
      - key: old-behaviour
        heading: Legacy Behaviour
        content: Old behaviour text.
        required: yes
        aliases:
          - Behaviour
      - key: behaviour
        heading: Behaviour
        content: Behaviour text.
        required: yes
EOF
run_validator "$reused_heading_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "already claimed" "$ERR"; then
  pass VTT-10
else
  fail_case VTT-10 "rc=$rc err=$(cat "$ERR")"
fi

# VTT-11 — duplicate catalog lookup tokens are ambiguous for section retrieval.
duplicate_token_template="$TMP/duplicate-token.md"
duplicate_token_catalog="$TMP/duplicate-token.yaml"
write_template "$duplicate_token_template" "fixture" $'# Fixture\n\n## Purpose\n\nText.\n\n## Behaviour\n\nText.\n\n## Current Behaviour\n\nText.'
cat > "$duplicate_token_catalog" <<EOF
document_shapes:
  fixture:
    template: $(fixture_rel "$duplicate_token_template")
    description: Fixture shape.
    sections:
      - key: purpose
        heading: Purpose
        content: Purpose text.
        required: yes
      - key: behaviour
        heading: Behaviour
        content: Behaviour text.
        required: yes
        aliases:
          - Legacy Behaviour
      - key: current-behaviour
        heading: Current Behaviour
        content: Current behaviour text.
        required: yes
        aliases:
          - Legacy Behaviour
EOF
run_validator "$duplicate_token_catalog"
rc=$?
if [ "$rc" = 1 ] && grep -q "failure" "$ERR" && grep -q "duplicate catalog lookup token" "$ERR"; then
  pass VTT-11
else
  fail_case VTT-11 "rc=$rc err=$(cat "$ERR")"
fi

[ "$fail" = 0 ] && echo "validate-template-taxonomy contract: ALL PASS" || exit 1
