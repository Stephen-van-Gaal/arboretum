#!/usr/bin/env bash
# owner: section-dispatch
# scope: plugin-only
# _smoke-test-section-dispatch.sh — accept a conformant registry, reject one per violation class.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-section-dispatch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail_count=0

cat > "$TMP/ok.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral-to-land-reviewers
workers:
  - id: ai-surface
    type: skill
    invoke: arboretum:ai-surface-review
  - id: codex
    type: runtime
    invoke: "node codex-companion.mjs review --json --base {base}"
    scrub: true
YML

cat > "$TMP/bad-no-type.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: mystery
    invoke: something
YML

cat > "$TMP/bad-no-contract.yml" <<'YML'
degradation: explicit-deferral
workers:
  - id: ai-surface
    type: skill
    invoke: arboretum:ai-surface-review
YML

cat > "$TMP/bad-runtime-no-scrub.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: codex
    type: runtime
    invoke: "node codex-companion.mjs review --json"
YML

cat > "$TMP/bad-no-degradation.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
workers:
  - id: ai-surface
    type: skill
    invoke: arboretum:ai-surface-review
YML

cat > "$TMP/ok-quoted.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: codex
    type: "runtime"
    invoke: "node codex-companion.mjs review --json"
    scrub: "true"
YML

cat > "$TMP/ok-comment.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: codex
    type: runtime   # external CLI reviewer
    invoke: "node codex-companion.mjs review --json"
    scrub: true     # untrusted output
YML

cat > "$TMP/bad-comment-only-contract.yml" <<'YML'
manifest_contract: # TODO fill this in
degradation: explicit-deferral
workers:
  - id: ai-surface
    type: skill
    invoke: arboretum:ai-surface-review
YML

cat > "$TMP/bad-no-invoke.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: codex
    type: runtime
    scrub: true
YML

cat > "$TMP/bad-quoted-hash.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral
workers:
  - id: codex
    type: "runtime # disabled"
    invoke: "node codex-companion.mjs review --json"
    scrub: true
YML

expect() { # <label> <file> <expected-exit>
  local label="$1" file="$2" want="$3" rc=0
  bash "$CHECK" "$file" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $rc" >&2; fail_count=$((fail_count+1))
  fi
}
expect "conformant"            "$TMP/ok.yml"                  0
expect "missing adapter type"  "$TMP/bad-no-type.yml"         1
expect "missing contract ref"  "$TMP/bad-no-contract.yml"     1
expect "runtime without scrub" "$TMP/bad-runtime-no-scrub.yml" 1
expect "missing degradation"   "$TMP/bad-no-degradation.yml"  1
expect "quoted scalars"        "$TMP/ok-quoted.yml"           0
expect "trailing comments"     "$TMP/ok-comment.yml"          0
expect "comment-only value"    "$TMP/bad-comment-only-contract.yml" 1
expect "missing invoke"        "$TMP/bad-no-invoke.yml"       1
expect "quoted hash in type"   "$TMP/bad-quoted-hash.yml"     1
if [ "$fail_count" -gt 0 ]; then echo "FAIL: $fail_count case(s)" >&2; exit 1; fi
echo "PASS: check-section-dispatch.sh — 10 cases"
