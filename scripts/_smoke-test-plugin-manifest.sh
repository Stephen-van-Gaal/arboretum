#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# _smoke-test-plugin-manifest.sh — guards Claude and Codex plugin metadata
# against installer-visible packaging mistakes.
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
#   Codex marketplace — Codex's local marketplace resolver ignores repo-root
#   source paths ("." or "./") even though the marketplace itself registers.
#   The entry must use the package path shape Codex lists:
#   "./plugins/arboretum", which resolves back to this plugin root.
#
# Asserts:
#   1. Claude and Codex plugin.json/marketplace.json files parse as JSON.
#   2. Every path-valued field (hooks, commands, agents, mcpServers,
#      lspServers, skills, outputStyles) that holds a string — or array of
#      strings — has each path starting with "./". Inline-object values
#      (valid for hooks/mcpServers/lspServers) carry no path and are skipped.
#   3. The `hooks` field, if a string, does not reference the auto-loaded
#      standard hooks file (hooks/hooks.json) — that would duplicate-load it.
#   4. The Codex marketplace points the `arboretum` plugin at the resolver-
#      visible `./plugins/arboretum` package path.
#   5. When the `codex` CLI is available, an isolated marketplace list command
#      can see `arboretum@arboretum`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

CLAUDE_PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
CLAUDE_MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"
CODEX_PLUGIN_JSON="$ROOT/.codex-plugin/plugin.json"
CODEX_MARKETPLACE_JSON="$ROOT/.agents/plugins/marketplace.json"
INIT_SKILL="$ROOT/skills/init/SKILL.md"

for f in "$CLAUDE_PLUGIN_JSON" "$CLAUDE_MARKETPLACE_JSON" "$CODEX_PLUGIN_JSON" "$CODEX_MARKETPLACE_JSON"; do
  [ -f "$f" ] || fail "manifest not found: $f"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" \
    || fail "invalid JSON: $f"
done

[ -f "$INIT_SKILL" ] || fail "init skill not found: $INIT_SKILL"
grep -qF '_smoke-test-*.sh) continue ;;' "$INIT_SKILL" \
  || fail "/init must not copy plugin smoke tests into consumer roots"

# Path-field check on plugin.json — names the offending field+value on failure.
python3 - "$CLAUDE_PLUGIN_JSON" <<'PY' || fail "plugin.json failed manifest path-field checks (see above)"
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

python3 - "$CODEX_PLUGIN_JSON" "$CODEX_MARKETPLACE_JSON" "$ROOT" <<'PY' \
  || fail "Codex marketplace failed root-source checks (see above)"
import json
import os
import sys

plugin_json, marketplace_json, root = sys.argv[1:]
plugin = json.load(open(plugin_json))
marketplace = json.load(open(marketplace_json))

bad = []
if plugin.get("name") != "arboretum":
    bad.append(f".codex-plugin/plugin.json name is {plugin.get('name')!r}, expected 'arboretum'")

entries = marketplace.get("plugins")
if not isinstance(entries, list):
    bad.append(".agents/plugins/marketplace.json plugins must be a list")
    entries = []

matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("name") == "arboretum"]
if len(matches) != 1:
    bad.append(f"expected exactly one arboretum marketplace entry, found {len(matches)}")
else:
    entry = matches[0]
    source = entry.get("source")
    if not isinstance(source, dict):
        bad.append("arboretum marketplace entry source must be an object")
        source = {}

    if source.get("source") != "local":
        bad.append(f"arboretum marketplace source.source is {source.get('source')!r}, expected 'local'")

    source_path = source.get("path")
    expected_source_path = "./plugins/arboretum"
    if source_path != expected_source_path:
        bad.append(
            f"arboretum marketplace source.path is {source_path!r}, "
            f"expected {expected_source_path!r}"
        )
    else:
        resolved = os.path.normpath(os.path.join(root, source_path))
        manifest = os.path.join(resolved, ".codex-plugin", "plugin.json")
        if not os.path.isfile(manifest):
            bad.append(f"arboretum marketplace source.path does not resolve to a Codex plugin manifest: {manifest}")

    symlink_path = os.path.join(root, "plugins", "arboretum")
    if not os.path.lexists(symlink_path):
        bad.append("plugins/arboretum must exist and resolve to the Codex plugin root")
    elif not os.path.isdir(symlink_path):
        bad.append("plugins/arboretum must resolve to a directory containing the plugin root")

if bad:
    print("Codex marketplace violations:", file=sys.stderr)
    for item in bad:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

if command -v codex >/dev/null 2>&1; then
  CODEX_SMOKE_HOME="$(mktemp -d)"
  cleanup_codex_smoke() { rm -rf "$CODEX_SMOKE_HOME"; }
  trap cleanup_codex_smoke EXIT

  CODEX_HOME="$CODEX_SMOKE_HOME" codex plugin marketplace add "$ROOT" >/dev/null \
    || fail "Codex marketplace resolver could not add the Arboretum marketplace"
  CODEX_HOME="$CODEX_SMOKE_HOME" codex plugin list --marketplace arboretum \
    | grep -q 'arboretum@arboretum' \
    || fail "Codex marketplace resolver did not list arboretum@arboretum"
else
  echo "SKIP: codex CLI not found; skipped Codex marketplace resolver smoke"
fi

echo "PASS: plugin metadata — valid JSON; Claude paths './'-prefixed; hooks not duplicated; Codex marketplace lists arboretum@arboretum when codex is available; /init excludes plugin smoke tests"
