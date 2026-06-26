#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-review-registry-filter.sh — unit test for scripts/review-registry-filter.sh
# (#791 D3). The dispatcher's deterministic selection step: registry.filter(altitude,
# artifact) + gate evaluation (section-dispatch element 2). Gates compose
# review-dispatch.sh's tested lane logic rather than reinventing it. Emits one JSONL
# worker record per selected reviewer, in registry (dispatch) order.
# Picked up by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/review-registry-filter.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REG="$REPO_ROOT/reviewers.yml"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# ids() — collapse JSONL worker records to a comma-joined id list, preserving order.
ids() { jq -rs '[.[].id] | join(",")'; }

# RRF-1 — finish/diff with an AI-facing + code change → all four lanes, in registry order.
files_full=$'skills/x/SKILL.md\nlib/foo.ts'
out="$(printf '%s\n' "$files_full" | bash "$PROBE" "$REG" --altitude finish --artifact diff --files-from -)"; rc=$?
got="$(printf '%s' "$out" | ids)"
if [ "$rc" = 0 ] && [ "$got" = "ai-surface,general-security,correctness,codex" ]; then pass RRF-1; else fail_case RRF-1 "rc=$rc got=$got"; fi

# RRF-2 — design/doc → only the codex row matches (the three skill lanes are finish-only).
got2="$(printf '' | bash "$PROBE" "$REG" --altitude design --artifact doc --files-from - | ids)"
[ "$got2" = "codex" ] && pass RRF-2 || fail_case RRF-2 "$got2"

# RRF-3 — gate drop: finish/diff over a non-AI, non-code change (a plain doc) drops the
# ai-surface (gate: ai-surface) and correctness (gate: code) rows; ungated lanes remain.
got3="$(printf 'README.md\n' | bash "$PROBE" "$REG" --altitude finish --artifact diff --files-from - | ids)"
[ "$got3" = "general-security,codex" ] && pass RRF-3 || fail_case RRF-3 "$got3"

# RRF-4 — --base substitutes {base} in the runtime row's invoke command.
inv="$(printf '%s\n' "$files_full" | bash "$PROBE" "$REG" --altitude finish --artifact diff --base origin/main --files-from - \
        | jq -rs 'first(.[] | select(.id=="codex")) | .invoke')"
case "$inv" in
  *"--base origin/main"*) [ "${inv/\{base\}/}" = "$inv" ] && pass RRF-4 || fail_case RRF-4 "placeholder survived: $inv" ;;
  *) fail_case RRF-4 "base not substituted: $inv" ;;
esac

# RRF-5 — artifact filter: finish/tree keeps only rows whose artifact includes tree
# (ai-surface, general-security); correctness ([diff]) and codex ([doc,diff]) drop.
got5="$(printf '%s\n' "$files_full" | bash "$PROBE" "$REG" --altitude finish --artifact tree --files-from - | ids)"
[ "$got5" = "ai-surface,general-security" ] && pass RRF-5 || fail_case RRF-5 "$got5"

# RRF-6 — each emitted record carries the fields the dispatcher needs (id, type, invoke).
shape="$(printf '%s\n' "$files_full" | bash "$PROBE" "$REG" --altitude finish --artifact diff --files-from - \
          | jq -rs 'all(.[]; has("id") and has("type") and has("invoke"))')"
[ "$shape" = true ] && pass RRF-6 || fail_case RRF-6 "$shape"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# RRF-7 — a trailing "# comment" on a flow list does not corrupt the CSV membership test
# (the artifact row still matches `diff` and the worker is selected).
cat > "$TMP/commented.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral-to-land-reviewers
workers:
  - id: only
    type: skill
    invoke: code-review
    altitudes: [finish]   # finish only
    artifact: [diff, tree]   # diff or tree
YML
got7="$(printf 'lib/foo.ts\n' | bash "$PROBE" "$TMP/commented.yml" --altitude finish --artifact diff --files-from - | jq -rs '[.[].id]|join(",")')"
[ "$got7" = "only" ] && pass RRF-7 || fail_case RRF-7 "commented flow list dropped the worker: got='$got7'"

# RRF-8 — a selected row missing a required field (empty type) fails loud (exit 2), never
# emits a malformed record the fan-out would choke on later.
cat > "$TMP/malformed.yml" <<'YML'
manifest_contract: docs/contracts/review-manifest.contract.md
degradation: explicit-deferral-to-land-reviewers
workers:
  - id: broken
    invoke: code-review
    altitudes: [finish]
    artifact: [diff]
YML
printf 'lib/foo.ts\n' | bash "$PROBE" "$TMP/malformed.yml" --altitude finish --artifact diff --files-from - >/dev/null 2>&1
[ "$?" = 2 ] && pass RRF-8 || fail_case RRF-8 "expected exit 2 on a selected row missing type"

# RRF-9 — a base carrying shell metacharacters is shell-quoted in the emitted invoke, so
# the runtime command /finish runs via Bash cannot execute an injected substitution.
inv9="$(printf '%s\n' "$files_full" | bash "$PROBE" "$REG" --altitude finish --artifact diff --base 'main$(touch pwned)' --files-from - \
        | jq -rs 'first(.[] | select(.id=="codex")) | .invoke')"
case "$inv9" in
  *'$(touch pwned)'*) fail_case RRF-9 "unquoted command substitution survived: $inv9" ;;
  *'main'*) pass RRF-9 ;;
  *) fail_case RRF-9 "base not substituted: $inv9" ;;
esac

[ "$fail" = 0 ] && echo "review-registry-filter: ALL PASS" || exit 1
