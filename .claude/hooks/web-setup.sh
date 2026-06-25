#!/usr/bin/env bash
# owner: arboretum-as-plugin
# scope: plugin-only
# SessionStart hook (web only): make the in-repo arboretum skills available.
#
# Why this exists
# ---------------
# arboretum-dev keeps its user-facing skills under `skills/` (the plugin
# location), which Claude Code only loads when the `arboretum` plugin is
# installed. On a fresh Claude-Code-on-the-web container the plugin is never
# installed — `~/.claude` is ephemeral and the interactive `/plugin install`
# flow does not persist — so `/start`, `/design`, `/finish`, … stay dark.
#
# How it installs the LOCAL working tree (not the public distribution)
# --------------------------------------------------------------------
# `.claude-plugin/marketplace.json` declares the plugin's `source` as the
# public github repo (stvangaal/arboretum) — correct for downstream adopters,
# wrong for dogfooding. `claude plugin install` honours that `source` and
# clones the public distribution even when the *catalog* is added as a local
# directory. The only local install path this CLI supports is a marketplace
# whose plugin `source` is `"."` (the marketplace root itself), which copies
# real files from that root.
#
# So this hook stages a copy of the local plugin — real working-tree files
# under `skills/` and `hooks/` plus the plugin manifest — into a runtime
# directory, writes a throwaway marketplace whose `source` is `"."`, and
# installs from it. The result is the exact in-development skills on the
# current branch (verified: copied, no .git, no github clone).
#
# Runs synchronously at SessionStart, but a long-running web CLI enumerates its
# skill registry once at launch — before this hook's install runs — so the
# freshly installed plugin does not reliably register in the same session (it
# appears unpredictably later, if at all within a short session; see #757).
# Turn-1 availability in the dogfood repo comes instead from the committed
# `.claude/skills/` mirror (scripts/generate-web-skill-mirror.sh), which is
# present in the clone before launch. This hook is retained as the
# local/persistent install path and as belt-and-braces for non-dogfood remote
# use. Fires for both `startup` and `resume` (a resumed web container is just as
# fresh: ~/.claude is ephemeral either way).
#
# Gates (no-op unless both hold):
#   * CLAUDE_CODE_REMOTE=true — web/remote container only. On a local machine
#     ~/.claude persists, so a one-time `/plugin install` is enough and we
#     don't want to shadow a developer's chosen install.
#   * dogfood: true in .arboretum.yml — arboretum-dev only. `.arboretum.yml`
#     is excluded from the public sync, so this hook is inert in the public
#     distribution and in downstream adopter projects, mirroring the dogfood
#     gate already used by session-start.sh.
#
# Bounded + best-effort: every `claude plugin` call is wrapped in `timeout`
# (and the hook carries a timeout in settings.json) so a hung CLI/cache lock
# degrades quickly to "skills not loaded" rather than stalling startup for the
# 600s synchronous-hook default. The script always exits 0.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── Gate 1: web/remote only ──────────────────────────────────────────
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

# ── Gate 2: arboretum-dev (dogfood) only ─────────────────────────────
DOGFOOD=$(sed -n 's/^dogfood:[[:space:]]*\([a-zA-Z]*\).*/\1/p' "$PROJECT_DIR/.arboretum.yml" 2>/dev/null || true)
[ "$DOGFOOD" = "true" ] || exit 0

# ── Need the CLI and a plugin manifest to stage ──────────────────────
command -v claude >/dev/null 2>&1 || exit 0
PLUGIN_MANIFEST="$PROJECT_DIR/.claude-plugin/plugin.json"
[ -f "$PLUGIN_MANIFEST" ] || exit 0
[ -d "$PROJECT_DIR/skills" ] || exit 0

MKT_NAME="arboretum-dev-local"
STAGE="$PROJECT_DIR/.arboretum/web-plugin"   # gitignored + sync-excluded runtime dir
VERSION=$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_MANIFEST" | head -1)
VERSION="${VERSION:-0.0.0}"

# ── Stage a real-file copy of the local plugin ───────────────────────
rm -rf "$STAGE"
mkdir -p "$STAGE/.claude-plugin"
cp "$PLUGIN_MANIFEST" "$STAGE/.claude-plugin/plugin.json"
cp -RL "$PROJECT_DIR/skills" "$STAGE/skills"
[ -d "$PROJECT_DIR/hooks" ] && cp -RL "$PROJECT_DIR/hooks" "$STAGE/hooks"
cat > "$STAGE/.claude-plugin/marketplace.json" <<EOF
{
  "name": "$MKT_NAME",
  "owner": { "name": "arboretum-dev" },
  "plugins": [
    { "name": "arboretum", "version": "$VERSION", "source": "." }
  ]
}
EOF

# ── Register the staged marketplace and install at user scope ─────────
# User scope keeps the repo working tree clean — the ephemeral ~/.claude
# config is rebuilt by this hook on every container boot. Each call is
# time-bounded; failures fall through to "skills not loaded", never a hang.
timeout 60 claude plugin marketplace add "$STAGE"        >/dev/null 2>&1 \
  || timeout 60 claude plugin marketplace update "$MKT_NAME" >/dev/null 2>&1 \
  || true
if ! timeout 90 claude plugin install "arboretum@$MKT_NAME" --scope user >/dev/null 2>&1; then
  # Already installed (e.g. resume after startup) — refresh from the restaged copy.
  timeout 90 claude plugin update arboretum >/dev/null 2>&1 || true
fi

# One concise line for Claude's context (SessionStart stdout → additionalContext).
# Turn-1 availability comes from the committed `.claude/skills/` mirror, not this
# install (the CLI enumerated skills at launch, before this hook ran). This line
# records that the persistent/local install path also completed.
# See docs/superpowers/specs/2026-06-16-web-session-boot-skill-load-design.md.
echo "[web-setup] Arboretum plugin install refreshed (local/persistent path). Turn-1 commands are served by the committed .claude/skills/ mirror."

exit 0
