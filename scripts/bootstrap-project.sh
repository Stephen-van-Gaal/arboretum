#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# bootstrap-project.sh — Initialize a new spec-driven project
#
# Usage:
#   ./bootstrap-project.sh <target-directory> [project-name]
#
# Creates the full directory structure, copies templates, installs hooks,
# and produces a ready-to-use project skeleton. If project-name is omitted,
# the directory name is used.
#
# This script is idempotent — it will not overwrite existing files.

set -euo pipefail

# ── Args ─────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [--layer N] <target-directory> [project-name]"
  echo ""
  echo "Creates a spec-driven project structure in the target directory."
  echo "If project-name is omitted, the directory basename is used."
  echo ""
  echo "Options:"
  echo "  --layer N   Only copy skills with layer <= N (default: 99, copies all)"
  exit 1
}

# Parse options
MAX_LAYER=99
while [ $# -gt 0 ]; do
  case "$1" in
    --layer)
      [ $# -lt 2 ] && usage
      MAX_LAYER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -lt 1 ]; then
  usage
fi

mkdir -p "$1"
TARGET_DIR="$(realpath "$1")"
PROJECT_NAME="${2:-$(basename "$TARGET_DIR")}"

# Find the script's own directory to locate templates
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Templates are at ../docs/templates/ relative to this script
TEMPLATES_DIR="$(realpath "$SCRIPT_DIR/../docs/templates")"
# Principles template is at ../docs/templates/PRINCIPLES.md (per issue #13).
# Skip realpath here: under `set -e`, realpath on a missing file aborts
# immediately and the "Verify source files exist" loop below — which
# prints the actionable "run this from the arboretum project directory"
# message — never runs. Simple path construction lets the existence
# check be the source of the user-facing error.
PRINCIPLES_FILE="$SCRIPT_DIR/../docs/templates/PRINCIPLES.md"
ARBORETUM_FILE="$SCRIPT_DIR/../docs/templates/ARBORETUM.md"
CLAUDE_TEMPLATE="$SCRIPT_DIR/../docs/templates/CLAUDE.md"
AGENTS_TEMPLATE="$SCRIPT_DIR/../docs/templates/AGENTS.md"
# Workflows are at ../workflows/
WORKFLOWS_DIR="$(realpath "$SCRIPT_DIR/../workflows")"
# Hooks are at ../.claude/
HOOKS_DIR="$(realpath "$SCRIPT_DIR/../.claude")"
# Git hooks are at ../.githooks/
GITHOOKS_DIR="$(realpath "$SCRIPT_DIR/../.githooks")"
# Skills are at ../.claude/skills/
SKILLS_DIR="$(realpath "$SCRIPT_DIR/../.claude/skills")"

# Verify source files exist
for f in "$TEMPLATES_DIR/spec.md" "$PRINCIPLES_FILE" "$ARBORETUM_FILE" "$CLAUDE_TEMPLATE" "$AGENTS_TEMPLATE" "$WORKFLOWS_DIR/README.md"; do
  if [ ! -f "$f" ]; then
    echo "Error: source file not found: $f"
    echo "Run this script from the arboretum project directory."
    exit 1
  fi
done

# ── Helper ───────────────────────────────────────────────────────────

copy_if_missing() {
  local src="$1"
  local dst="$2"
  # -e (not -f) so directory destinations are guarded too: a re-run must
  # skip an existing dir, else `cp -R` would nest src *inside* it.
  if [ -e "$dst" ]; then
    echo "  exists: $(basename "$dst")"
  else
    # -R so directory templates (e.g. docs/templates/issue-templates/)
    # copy recursively instead of aborting the run under set -euo pipefail.
    cp -R "$src" "$dst"
    echo "  created: $(basename "$dst")"
  fi
}

mkdir_if_missing() {
  local dir="$1"
  if [ -d "$dir" ]; then
    echo "  exists: $dir"
  else
    mkdir -p "$dir"
    echo "  created: $dir"
  fi
}

# ── Create directory structure ───────────────────────────────────────

echo "Bootstrapping spec-driven project: $PROJECT_NAME"
echo "Target: $TARGET_DIR"
echo ""

echo "Creating directory structure..."
mkdir_if_missing "$TARGET_DIR"
mkdir_if_missing "$TARGET_DIR/docs"
mkdir_if_missing "$TARGET_DIR/docs/definitions"
mkdir_if_missing "$TARGET_DIR/docs/specs"
mkdir_if_missing "$TARGET_DIR/docs/reference"
mkdir_if_missing "$TARGET_DIR/docs/plans"
mkdir_if_missing "$TARGET_DIR/docs/templates"
mkdir_if_missing "$TARGET_DIR/workflows"
mkdir_if_missing "$TARGET_DIR/.claude"
mkdir_if_missing "$TARGET_DIR/.claude/hooks"

# ── Copy principles and workflows ────────────────────────────────────

echo ""
echo "Copying principles and workflows..."
copy_if_missing "$PRINCIPLES_FILE" "$TARGET_DIR/PRINCIPLES.md"
copy_if_missing "$ARBORETUM_FILE" "$TARGET_DIR/ARBORETUM.md"
for wf in "$WORKFLOWS_DIR"/*.md; do
  basename_wf="$(basename "$wf")"
  copy_if_missing "$wf" "$TARGET_DIR/workflows/$basename_wf"
done

# ── Copy templates ───────────────────────────────────────────────────

echo ""
echo "Copying templates..."
for tmpl in "$TEMPLATES_DIR"/*; do
  basename_tmpl="$(basename "$tmpl")"
  copy_if_missing "$tmpl" "$TARGET_DIR/docs/templates/$basename_tmpl"
done

# ── Copy reserved spec templates into docs/specs/ ────────────────────

echo ""
echo "Copying reserved specs..."
for reserved in test-infrastructure.spec.md project-infrastructure.spec.md; do
  if [ -f "$TEMPLATES_DIR/$reserved" ]; then
    copy_if_missing "$TEMPLATES_DIR/$reserved" "$TARGET_DIR/docs/specs/$reserved"
  fi
done

# ── Copy hooks ───────────────────────────────────────────────────────

echo ""
echo "Copying hooks..."
# Session-start hook: always (Layer 0+)
copy_if_missing "$HOOKS_DIR/hooks/session-start.sh" "$TARGET_DIR/.claude/hooks/session-start.sh"
# Pre-commit branch check + worktree write-guard: Layer 2+ only
if [ "$MAX_LAYER" -ge 2 ]; then
  copy_if_missing "$HOOKS_DIR/hooks/pre-commit-branch-check.sh" "$TARGET_DIR/.claude/hooks/pre-commit-branch-check.sh"
  copy_if_missing "$HOOKS_DIR/hooks/worktree-write-guard.sh" "$TARGET_DIR/.claude/hooks/worktree-write-guard.sh"
fi
chmod +x "$TARGET_DIR/.claude/hooks"/*.sh 2>/dev/null || true

# Generate settings.json based on layer
if [ -f "$TARGET_DIR/.claude/settings.json" ]; then
  echo "  exists: settings.json"
else
  if [ "$MAX_LAYER" -ge 2 ]; then
    # Full settings: session-start + pre-commit branch check
    copy_if_missing "$HOOKS_DIR/settings.json" "$TARGET_DIR/.claude/settings.json"
  else
    # Layer 0-1: session-start only
    cat > "$TARGET_DIR/.claude/settings.json" << 'SETTINGS'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
    echo "  created: settings.json"
  fi
fi

# ── Copy git hooks ────────────────────────────────────────────────────

echo ""
echo "Copying git hooks..."
mkdir_if_missing "$TARGET_DIR/.githooks"
for hook in "$GITHOOKS_DIR"/*; do
  basename_hook="$(basename "$hook")"
  copy_if_missing "$hook" "$TARGET_DIR/.githooks/$basename_hook"
done
chmod +x "$TARGET_DIR/.githooks"/* 2>/dev/null || true

# ── Copy skills ──────────────────────────────────────────────────────

echo ""
echo "Copying skills..."
if [ -d "$SKILLS_DIR" ]; then
  for skill_dir in "$SKILLS_DIR"/*/; do
    [ ! -d "$skill_dir" ] && continue
    skill_name="$(basename "$skill_dir")"
    # Skip dogfood web-session mirror entries (symlinks into ../../skills). They
    # are a dev-repo-only turn-1 workaround (design D5); following them here would
    # copy a partial skill set into a bootstrapped project, leaving a callable
    # /start that hands off to commands that were never installed.
    if [ -L "${skill_dir%/}" ]; then
      echo "  skipped (mirror symlink: $skill_name)"
      continue
    fi
    # Skip dev-prefixed and archived skills
    if [[ "$skill_name" == dev-* || "$skill_name" == _archived ]]; then
      echo "  skipped ($skill_name)"
      continue
    fi
    # Only copy if SKILL.md exists
    if [ -f "$skill_dir/SKILL.md" ]; then
      # Extract layer from SKILL.md frontmatter
      skill_layer=$(sed -n '/^---$/,/^---$/{ s/^layer:[[:space:]]*\([0-9]\).*/\1/p; }' "$skill_dir/SKILL.md")
      skill_layer="${skill_layer:-0}"
      if [ "$skill_layer" -gt "$MAX_LAYER" ]; then
        echo "  skipped (layer $skill_layer > $MAX_LAYER): $skill_name"
        continue
      fi
      mkdir_if_missing "$TARGET_DIR/.claude/skills/$skill_name"
      copy_if_missing "$skill_dir/SKILL.md" "$TARGET_DIR/.claude/skills/$skill_name/SKILL.md"
    fi
  done
else
  echo "  no skills directory found — skipping"
fi

# ── Create CLAUDE.md from template ───────────────────────────────────

echo ""
echo "Creating CLAUDE.md..."
if [ -f "$TARGET_DIR/CLAUDE.md" ]; then
  echo "  exists: CLAUDE.md"
else
  sed "s/# CLAUDE.md/# CLAUDE.md — $PROJECT_NAME/" \
    "$CLAUDE_TEMPLATE" > "$TARGET_DIR/CLAUDE.md"
  echo "  created: CLAUDE.md"
fi

# ── Create AGENTS.md from template ───────────────────────────────────

echo ""
echo "Creating AGENTS.md..."
if [ -f "$TARGET_DIR/AGENTS.md" ]; then
  echo "  exists: AGENTS.md"
else
  sed "s/# AGENTS.md/# AGENTS.md — $PROJECT_NAME/" \
    "$AGENTS_TEMPLATE" > "$TARGET_DIR/AGENTS.md"
  echo "  created: AGENTS.md"
fi

# ── Create empty contracts.yaml ──────────────────────────────────────

echo ""
echo "Creating contracts.yaml..."
copy_if_missing "$TEMPLATES_DIR/contracts.yaml" "$TARGET_DIR/contracts.yaml"

# ── Create .publishignore ─────────────────────────────────────────────

echo ""
echo "Creating .publishignore..."
copy_if_missing "$TEMPLATES_DIR/publishignore" "$TARGET_DIR/.publishignore"

# ── Create .arboretum.yml ──────────────────────────────────────────────

echo ""
echo "Creating .arboretum.yml..."
if [ -f "$TARGET_DIR/.arboretum.yml" ]; then
  echo "  exists: .arboretum.yml"
else
  cat > "$TARGET_DIR/.arboretum.yml" << 'ARBORETUM'
# Arboretum project configuration
# layer: 0 = foundation, 1 = structure, 2 = governance
layer: 0
# Tracker/repo backend. Default: github. Future: azure-devops.
backend: github
# Patch-lane workflow config.
patch_lane:
  investigation_budget_minutes: 15
ARBORETUM
  echo "  created: .arboretum.yml"
  # Seed the journey-log author allowlist (#249) via the lifecycle helper.
  # Additive-only: no-op if a trust block already exists. Best-effort on gh —
  # writes a hinted placeholder + bot and warns if the login can't be resolved.
  if bash "$(dirname "$0")/manage-trust.sh" instantiate "$TARGET_DIR/.arboretum.yml"; then
    echo "  seeded: trust.journey_log_authors"
  else
    echo "  warning: trust allowlist not seeded — run /upgrade or edit .arboretum.yml"
  fi
fi

# ── Initialize git if needed ─────────────────────────────────────────

echo ""
if [ -d "$TARGET_DIR/.git" ]; then
  echo "Git repo already exists."
else
  echo "Initializing git repository..."
  (cd "$TARGET_DIR" && git init -q)
  echo "  initialized."
fi

# Configure git to use .githooks directory
echo ""
echo "Configuring git hooks path..."
current_hooks_path=$(cd "$TARGET_DIR" && git config core.hooksPath 2>/dev/null || true)
if [ "$current_hooks_path" = ".githooks" ]; then
  echo "  already set: core.hooksPath = .githooks"
else
  (cd "$TARGET_DIR" && git config core.hooksPath .githooks)
  echo "  configured: core.hooksPath = .githooks"
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "Done. Project structure:"
echo ""
echo "  $TARGET_DIR/"
echo "  ├── CLAUDE.md                    # AI entry point"
echo "  ├── AGENTS.md                    # Codex entry point"
echo "  ├── ARBORETUM.md                 # Agent workflow contract"
echo "  ├── PRINCIPLES.md                # Seven principles"
echo "  ├── contracts.yaml               # Version pins (empty)"
echo "  ├── .publishignore               # Public repo exclusions"
echo "  ├── .arboretum.yml               # Project config"
echo "  ├── workflows/                   # Workflow definitions"
echo "  ├── .githooks/                   # Git hooks (secrets, validation)"
echo "  ├── .claude/"
echo "  │   ├── settings.json            # Hook configuration"
echo "  │   ├── hooks/                   # Automation hooks"
echo "  │   └── skills/                  # Framework skills"
echo "  └── docs/"
echo "      ├── templates/               # Starter templates"
echo "      ├── definitions/             # (empty — create from architecture)"
echo "      ├── specs/                   # Reserved specs"
echo "      ├── reference/               # (empty — add domain knowledge)"
echo "      └── plans/                   # (empty — add during implementation)"
echo ""
echo "Next steps:"
echo "  1. Edit CLAUDE.md / AGENTS.md with your project overview"
echo "  2. Run /architect to design your architecture"
echo "  3. Use /start to begin your first feature"
