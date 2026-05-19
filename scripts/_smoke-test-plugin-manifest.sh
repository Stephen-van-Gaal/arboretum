#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# _smoke-test-plugin-manifest.sh — guards .claude-plugin/plugin.json against
# the manifest-validation rules Claude Code enforces at plugin install time.
#
# Regression guard for two related manifest bugs:
#
#   #268 — the `hooks` path field shipped as "hooks/hooks.json" (no `./`
#   prefix). Claude Code's manifest validator rejects bare relative paths
#   ("Validation errors: hooks: Invalid input"), making the published plugin
#   un-installable.
#
#   #289 — the `hooks` field then pointed at "./hooks/hooks.json". That value
#   validates, but Claude Code auto-loads the standard hooks/hooks.json, so
#   the hook loader rejects the duplicate ("Duplicate hooks file detected").
#   manifest.hooks must reference *additional* hook files only.
#
# check-version-bump.sh only checks version fields, so neither malformed
# value tripped any other gate.
#
# Asserts:
#   1. plugin.json and marketplace.json parse as JSON.
#   2. Every path-valued field (hooks, commands, agents, mcpServers,
#      lspServers, skills, outputStyles) that holds a string — or array of
#      strings — has each path starting with "./". Inline-object values
#      (valid for hooks/mcpServers/lspServers) carry no path and are skipped.
#   3. The `hooks` field, if a string, does not reference the auto-loaded
#      standard hooks file (hooks/hooks.json) — that would duplicate-load it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"

for f in "$PLUGIN_JSON" "$MARKETPLACE_JSON"; do
  [ -f "$f" ] || fail "manifest not found: $f"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" \
    || fail "invalid JSON: $f"
done

# Path-field check on plugin.json — names the offending field+value on failure.
python3 - "$PLUGIN_JSON" <<'PY' || fail "plugin.json failed manifest path-field checks (see above)"
import json, sys

manifest = json.load(open(sys.argv[1]))
PATH_FIELDS = ("hooks", "commands", "agents", "mcpServers",
               "lspServers", "skills", "outputStyles")

bad = []
for field in PATH_FIELDS:
    value = manifest.get(field)
    if isinstance(value, str):
        paths = [value]
    elif isinstance(value, list):
        paths = [p for p in value if isinstance(p, str)]
    else:
        paths = []  # absent, or inline object — nothing to validate
    for p in paths:
        if not p.startswith("./"):
            bad.append(f"{field}: {p!r} — must start with './'")

# manifest.hooks must reference *additional* hook files only — never the
# standard hooks/hooks.json, which Claude Code auto-loads. Pointing it there
# makes the loader load the same file twice ("Duplicate hooks file
# detected"). Regression guard for issue #289.
STANDARD_HOOKS = ("./hooks/hooks.json", "hooks/hooks.json")
hooks_value = manifest.get("hooks")
if isinstance(hooks_value, str) and hooks_value in STANDARD_HOOKS:
    bad.append(f"hooks: {hooks_value!r} — references the auto-loaded standard "
               "hooks file; omit the field (additional hook files only)")

if bad:
    print("manifest path-field violations:", file=sys.stderr)
    for b in bad:
        print(f"  {b}", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: plugin manifest — valid JSON; path fields './'-prefixed; hooks not duplicating the standard file"
