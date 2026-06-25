#!/usr/bin/env bash
# owner: review-stage
# scope: plugin-only
# Smoke test for scripts/resolve-codex-companion.sh (#800).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/resolve-codex-companion.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Build a fixture plugin cache:
#   <cache>/mp/codex/<ver>/.claude-plugin/plugin.json + scripts/codex-companion.mjs
make_codex() { # $1=cache root, $2=version → echoes the companion abspath
  local d="$1/mp/codex/$2"
  mkdir -p "$d/.claude-plugin" "$d/scripts"
  printf '{ "name": "codex", "author": { "name": "OpenAI" } }\n' > "$d/.claude-plugin/plugin.json"
  printf '// companion\n' > "$d/scripts/codex-companion.mjs"
  printf '%s' "$d/scripts/codex-companion.mjs"
}

cacheA="$(mktemp -d)"
cacheB="$(mktemp -d)"
cacheC="$(mktemp -d)"
trap 'rm -rf "$cacheA" "$cacheB" "$cacheC"' EXIT

# Case A: found → prints existing abspath, exit 0
expectA="$(make_codex "$cacheA" 1.0.4)"
got="$(ARBO_PLUGIN_CACHE="$cacheA" bash "$SCRIPT")" || fail "A: nonzero exit when companion present"
[ "$got" = "$expectA" ] || fail "A: expected $expectA, got $got"
[ -f "$got" ] || fail "A: printed path does not exist"

# Case B: not found → empty stdout, nonzero exit
if out="$(ARBO_PLUGIN_CACHE="$cacheB" bash "$SCRIPT" 2>/dev/null)"; then
  fail "B: expected nonzero exit when no codex plugin"
fi
[ -z "${out:-}" ] || fail "B: expected empty stdout, got $out"

# Case C: multiple versions → highest wins (1.10.0 > 1.2.0 via sort -V)
make_codex "$cacheC" 1.2.0 >/dev/null
expectC="$(make_codex "$cacheC" 1.10.0)"
gotC="$(ARBO_PLUGIN_CACHE="$cacheC" bash "$SCRIPT")" || fail "C: nonzero exit"
[ "$gotC" = "$expectC" ] || fail "C: expected highest version $expectC, got $gotC"

# Case D: a non-codex plugin whose nested author.name is "codex" must NOT match —
# only the top-level "name" selects the plugin (regression for the line-oriented
# grep that matched author.name).
cacheD="$(mktemp -d)"; trap 'rm -rf "$cacheA" "$cacheB" "$cacheC" "$cacheD"' EXIT
dD="$cacheD/mp/codexish/1.0.0"
mkdir -p "$dD/.claude-plugin" "$dD/scripts"
printf '{ "name": "codexish", "author": { "name": "codex" } }\n' > "$dD/.claude-plugin/plugin.json"
printf '// not the codex companion\n' > "$dD/scripts/codex-companion.mjs"
if outD="$(ARBO_PLUGIN_CACHE="$cacheD" bash "$SCRIPT" 2>/dev/null)"; then
  fail "D: matched a plugin whose only 'codex' is author.name (got $outD)"
fi

echo "PASS: resolve-codex-companion smoke test"
