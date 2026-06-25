#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# _smoke-test-validate-coverage-manifest.sh — Exercises both
# generate-coverage.sh (the regenerator) and validate-coverage-manifest.sh
# (the integrity checker) against a fixture project.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$REPO_ROOT/scripts/generate-coverage.sh"
VAL="$REPO_ROOT/scripts/validate-coverage-manifest.sh"

[ -x "$GEN" ] || { echo "FAIL: $GEN not found or not executable" >&2; exit 1; }
[ -x "$VAL" ] || { echo "FAIL: $VAL not found or not executable" >&2; exit 1; }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT
fix="$ROOT_TMP/fixture"

mkdir -p "$fix/scripts" "$fix/.claude/hooks" "$fix/docs/contracts"
touch "$fix/scripts/example-a.sh"
touch "$fix/scripts/example-b.sh"
touch "$fix/.claude/hooks/example-hook.sh"

# Create one CLI contract that covers example-a.sh
cat > "$fix/docs/contracts/example-a.cli-contract.md" <<'INNER'
---
script: scripts/example-a.sh
version: 1.0
invokers:
  - type: developer
related-designs:
  - docs/superpowers/specs/example.md
---
# Contract for example-a
## Surface
example
## Protocol
### Arguments
none
### Exit codes
- `0` — success
### Side effects
none
## Test surface
- **A-1:** noop
## Versioning
- **1.0** — initial
INNER

# Create one full contract that covers example-b.sh and the hook
cat > "$fix/docs/contracts/example-bundle.contract.md" <<'INNER'
---
seam: example-bundle
version: 1.0
producer-type: script
consumer-type: hook
consumes: []
produces: []
related-designs:
  - docs/superpowers/specs/example.md
script: scripts/example-b.sh
owns:
  - scripts/example-b.sh
  - .claude/hooks/example-hook.sh
---
# bundle
## Producer
scripts/example-b.sh
## Consumer
hook
## Protocol shape
### Inputs
none
### Outputs
none
### Invariants
none
## Test surface
- B-1: noop
## Versioning
- 1.0 initial
INNER

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; fail=1; }

# Case 1: regen creates a deterministic manifest covering all 3 scripts/hooks
( cd "$fix" && bash "$GEN" >/dev/null )
if [ -f "$fix/docs/contracts/_coverage.md" ]; then
  pass "case 1 — generate-coverage produces _coverage.md"
else
  fail_case "case 1 — _coverage.md not created"
fi

# Case 2: regen is idempotent (running twice produces identical output)
( cd "$fix" && bash "$GEN" >/dev/null )
first=$(cat "$fix/docs/contracts/_coverage.md")
( cd "$fix" && bash "$GEN" >/dev/null )
second=$(cat "$fix/docs/contracts/_coverage.md")
if [ "$first" = "$second" ]; then
  pass "case 2 — generate-coverage is idempotent"
else
  fail_case "case 2 — second run produced different output"
fi

# Case 3: validator passes on fresh manifest
if ( cd "$fix" && bash "$VAL" ) >/dev/null 2>&1; then
  pass "case 3 — validator passes on fresh manifest"
else
  fail_case "case 3 — validator should pass on fresh manifest"
fi

# Case 4: validator fails on stale manifest
echo "stale junk" > "$fix/docs/contracts/_coverage.md"
if ( cd "$fix" && bash "$VAL" ) >/dev/null 2>&1; then
  fail_case "case 4 — validator should fail on stale manifest"
else
  pass "case 4 — validator fails on stale manifest"
fi

# Case 5: validator fails when a script lacks a manifest row
( cd "$fix" && bash "$GEN" >/dev/null )       # regen clean
touch "$fix/scripts/example-uncovered.sh"     # add a script without contract
if ( cd "$fix" && bash "$VAL" ) >/dev/null 2>&1; then
  fail_case "case 5 — validator should fail when script lacks a row"
else
  pass "case 5 — validator fails on missing-row condition"
fi

# Case 6: bootstrap mode triggers when no cli-contracts exist
# Remove the only cli-contract; validator should warn + exit 0 regardless of
# manifest state. Tests the "cli-contract presence" criterion (per design
# §D6 revision).
rm -f "$fix/scripts/example-uncovered.sh"
rm "$fix/docs/contracts/example-a.cli-contract.md"
( cd "$fix" && bash "$GEN" >/dev/null )       # regen — full-contract-only manifest
if ( cd "$fix" && bash "$VAL" ) 2>/dev/null; then
  pass "case 6 — bootstrap mode triggers when no cli-contracts exist"
else
  fail_case "case 6 — bootstrap mode should exit 0 when no cli-contracts present"
fi

# Case 7: bootstrap mode triggers when docs/contracts does not exist
bare="$ROOT_TMP/bare"
mkdir -p "$bare/scripts"
if ( cd "$bare" && bash "$VAL" ) 2>/dev/null; then
  pass "case 7 — bootstrap mode triggers when docs/contracts is absent"
else
  fail_case "case 7 — bootstrap mode should exit 0 when docs/contracts is absent"
fi

# Case 8: missing docs/contracts fails in a plugin-capable root
pluginish="$ROOT_TMP/pluginish"
mkdir -p "$pluginish/scripts" "$pluginish/.codex-plugin"
printf '{"version":"0.0.0"}\n' > "$pluginish/.codex-plugin/plugin.json"
if ( cd "$pluginish" && bash "$VAL" ) >/dev/null 2>&1; then
  fail_case "case 8 — plugin-capable root should fail when docs/contracts is absent"
else
  pass "case 8 — plugin-capable root fails when docs/contracts is absent"
fi

[ $fail -eq 0 ] && echo "All validate-coverage-manifest smoke cases passed." || exit 1
