---
name: init
owner: arboretum-as-plugin
description: Initialize a new arboretum-governed project — scaffolds the directory structure, copies templates and hooks from the plugin, generates CLAUDE.md and AGENTS.md, configures git, and hands off to /architect for the project-shape interview. Use after installing the arboretum plugin in an empty (or near-empty) directory.
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
layer: 0
---

# Initialize Arboretum Project

Scaffold a new arboretum-governed project from the installed plugin. Replaces the legacy `scripts/bootstrap-project.sh` CLI by running entirely inside Claude Code with access to the plugin's templates, workflows, and hooks via `${CLAUDE_PLUGIN_ROOT}`.

## When to invoke

- User runs `/arboretum:init` in a new or near-empty project directory.
- The arboretum plugin is installed (this skill is unavailable otherwise).
- This skill is **idempotent** — running it again over a partially-scaffolded project will create only what's missing and leave existing files alone.

## Procedure

### Step 1: Confirm scope

Determine the target directory. Default is the current working directory; only ask if `$ARGUMENTS` carries an explicit alternative path.

Determine the project name. Default is the basename of the target directory. Confirm with the user using AskUserQuestion if the basename looks generic (e.g. `tmp`, `test`, `new-project`) — otherwise accept silently.

Detect existing state by checking which of these already exist in the target:

```bash
for f in CLAUDE.md AGENTS.md ARBORETUM.md PRINCIPLES.md docs workflows .claude .githooks; do
  [ -e "$f" ] && echo "exists: $f"
done
```

If any of these exist, tell the user: "I'll fill in what's missing without overwriting anything that's already there." Then continue.

### Step 2: Verify superpowers is installed

Arboretum's workflows delegate to superpowers for brainstorming, planning, TDD, and several other process skills. The plugin format does not currently express cross-plugin dependencies in the manifest, so this skill checks for superpowers explicitly. The check searches all installed plugin manifests for the one declaring `name: superpowers` rather than hard-coding a marketplace namespace path — different marketplaces install plugins under different cache subdirectories.

```bash
PLUGIN_CACHE_DIR="$HOME/.claude/plugins/cache"
SUPERPOWERS_DIR="$(
  find "$PLUGIN_CACHE_DIR" -type f -path '*/.claude-plugin/plugin.json' 2>/dev/null | while read -r plugin_json; do
    if grep -Eq '"name"[[:space:]]*:[[:space:]]*"superpowers"' "$plugin_json"; then
      dirname "$(dirname "$plugin_json")"
      break
    fi
  done
)"

if [ -n "$SUPERPOWERS_DIR" ] && [ -d "$SUPERPOWERS_DIR" ]; then
  echo "superpowers: installed"
else
  echo "superpowers: NOT installed"
fi
```

If superpowers is not installed, tell the user: "Arboretum workflows depend on superpowers for brainstorming, planning, and TDD. Install it with `/plugin install superpowers` from the official Claude marketplace, then re-run `/arboretum:init`." Stop here.

### Step 3: Create directory structure

```bash
mkdir -p docs/specs docs/plans docs/definitions docs/reference docs/templates
mkdir -p workflows
mkdir -p .claude/hooks
mkdir -p .github/ISSUE_TEMPLATE
mkdir -p .githooks
```

### Step 4: Copy framework files from the plugin

Source paths use `${CLAUDE_PLUGIN_ROOT}`. (Phase 9 of the migration moves templates/ to plugin root; until then, paths use the dev-workspace layout.)

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT not set — is the plugin installed?}"

# Helper: copy only if destination is missing
copy_if_missing() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    echo "  exists: $dst"
  else
    cp "$src" "$dst"
    echo "  created: $dst"
  fi
}

# Principles template → project root (per issue #13: PRINCIPLES.md
# lives under docs/templates/ in the plugin so adopters know to edit
# the broken cross-refs).
copy_if_missing "$PLUGIN_ROOT/docs/templates/PRINCIPLES.md" "PRINCIPLES.md"
copy_if_missing "$PLUGIN_ROOT/docs/templates/ARBORETUM.md" "ARBORETUM.md"

# Workflows
for wf in "$PLUGIN_ROOT/workflows/"*.md; do
  copy_if_missing "$wf" "workflows/$(basename "$wf")"
done

# Templates
for tmpl in "$PLUGIN_ROOT/docs/templates/"*; do
  copy_if_missing "$tmpl" "docs/templates/$(basename "$tmpl")"
done

# Reserved specs (live in docs/specs/, not docs/templates/)
for reserved in test-infrastructure.spec.md project-infrastructure.spec.md; do
  if [ -f "$PLUGIN_ROOT/docs/templates/$reserved" ]; then
    copy_if_missing "$PLUGIN_ROOT/docs/templates/$reserved" "docs/specs/$reserved"
  fi
done

# Session-start hook
copy_if_missing "$PLUGIN_ROOT/.claude/hooks/session-start.sh" ".claude/hooks/session-start.sh"
chmod +x .claude/hooks/session-start.sh 2>/dev/null || true

# Git hooks
for hook in "$PLUGIN_ROOT/.githooks/"*; do
  copy_if_missing "$hook" ".githooks/$(basename "$hook")"
done
chmod +x .githooks/* 2>/dev/null || true

# Governance scripts (health-check, generate-register, validate-cross-refs,
# sync-contracts). These are the plumbing that /finish, /pr, /health-check,
# /consolidate, and /init-project shell out to. Skip bootstrap-project.sh
# (legacy bootstrap CLI superseded by this very skill) and plugin self-tests.
mkdir -p scripts
for script in "$PLUGIN_ROOT/scripts/"*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"
  case "$name" in
    bootstrap-project.sh) continue ;;
    _smoke-test-*.sh) continue ;;
  esac
  copy_if_missing "$script" "scripts/$name"
done
chmod +x scripts/*.sh 2>/dev/null || true

# Roadmap scripts live in a subdirectory; the glob above is non-recursive
# and would otherwise miss them (lib.sh, render-run.sh, maintain-*.sh, …),
# leaving /roadmap broken in the new project.
mkdir -p scripts/roadmap
for script in "$PLUGIN_ROOT/scripts/roadmap/"*.sh; do
  [ -f "$script" ] || continue
  copy_if_missing "$script" "scripts/roadmap/$(basename "$script")"
done
chmod +x scripts/roadmap/*.sh 2>/dev/null || true

# Library helpers (upgrade classifier and future helpers) live in scripts/lib/.
# upgrade-sync.sh sources scripts/lib/upgrade-classify.sh at runtime, so it
# must be present in the project tree alongside the other managed scripts.
mkdir -p scripts/lib
for script in "$PLUGIN_ROOT/scripts/lib/"*.sh; do
  [ -f "$script" ] || continue
  copy_if_missing "$script" "scripts/lib/$(basename "$script")"
done
chmod +x scripts/lib/*.sh 2>/dev/null || true
```

### Step 5: Generate CLAUDE.md and AGENTS.md from templates

CLAUDE.md and AGENTS.md are thin tool entrypoints. Their templates live at `${CLAUDE_PLUGIN_ROOT}/docs/templates/CLAUDE.md` and `${CLAUDE_PLUGIN_ROOT}/docs/templates/AGENTS.md`. Substitute the project name into each title.

```bash
# PROJECT_NAME comes from Step 1 (basename or user-confirmed override).
# Fall back to basename so the sed never produces an empty title even if
# upstream wiring missed setting it.
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PWD")}"

if [ -f CLAUDE.md ]; then
  echo "  exists: CLAUDE.md"
else
  sed "s/^# CLAUDE.md\$/# CLAUDE.md — $PROJECT_NAME/" \
    "$PLUGIN_ROOT/docs/templates/CLAUDE.md" > CLAUDE.md
  echo "  created: CLAUDE.md"
fi

if [ -f AGENTS.md ]; then
  echo "  exists: AGENTS.md"
else
  sed "s/^# AGENTS.md\$/# AGENTS.md — $PROJECT_NAME/" \
    "$PLUGIN_ROOT/docs/templates/AGENTS.md" > AGENTS.md
  echo "  created: AGENTS.md"
fi
```

### Step 6: Configuration files

Generate `.claude/settings.json`, `contracts.yaml`, `.publishignore`, and `.arboretum.yml`.

```bash
# settings.json — SessionStart hook + governance allow list.
# seed-settings.sh copies the template when settings.json is absent, and
# merges the allow list (preserving existing hooks and entries) when it
# already exists.
bash "$PLUGIN_ROOT/scripts/seed-settings.sh" \
  ".claude/settings.json" \
  "$PLUGIN_ROOT/docs/templates/settings.json.template"

# contracts.yaml + .publishignore from templates
copy_if_missing "$PLUGIN_ROOT/docs/templates/contracts.yaml" "contracts.yaml"
copy_if_missing "$PLUGIN_ROOT/docs/templates/publishignore" ".publishignore"

# .arboretum.yml — defaults to layer 0 (foundation)
if [ ! -f .arboretum.yml ]; then
  cat > .arboretum.yml <<'YAML'
# Arboretum project configuration
# layer: 0 = foundation, 1 = structure, 2 = governance
layer: 0
# Tracker/repo backend. Default: github. Future: azure-devops.
backend: github
YAML
  echo "  created: .arboretum.yml"
fi
```

### Step 6b: Seed the install manifest

After copying framework files and generating `.arboretum.yml`, seed the install
manifest so the project records the baseline version and hashes of every vendored
file. Fresh copies equal the plugin, so every managed file gets a real base — no
spurious conflicts on the first `/upgrade`.

```bash
bash scripts/upgrade-sync.sh --bootstrap-manifest
echo "  seeded: .arboretum/install-manifest.json"
```

If `upgrade-sync.sh` is not yet present in `scripts/` (e.g. an older plugin
version that predates the upgrade system), skip this step silently and continue.

### Step 7: Initialize git

```bash
if [ ! -d .git ]; then
  git init -q
  echo "  initialized: git repo"
fi

# Point git to the project's hooks directory
current_hooks_path=$(git config core.hooksPath 2>/dev/null || true)
if [ "$current_hooks_path" != ".githooks" ]; then
  git config core.hooksPath .githooks
  echo "  configured: core.hooksPath = .githooks"
fi
```

### Step 8: Summary

Report what was created vs. what was already present. Then describe the layout in plain prose so the user can orient quickly:

```
project/
├── CLAUDE.md                AI entry point
├── AGENTS.md                Codex entry point
├── ARBORETUM.md             Agent workflow contract
├── PRINCIPLES.md            Seven principles (read-only)
├── contracts.yaml           Version pins (Layer 2+)
├── .publishignore           Public-repo exclusions
├── .arboretum.yml           Project config (layer)
├── workflows/               Workflow definitions
├── .githooks/               Git hooks (secrets, validation)
├── .claude/
│   ├── settings.json        Hook configuration
│   └── hooks/               SessionStart audits
└── docs/
    ├── templates/           Starter templates
    ├── specs/               Governed specs (and reserved infra specs)
    ├── plans/               Ephemeral implementation plans
    ├── definitions/         Shared types and contracts (Layer 1+)
    └── reference/           Domain knowledge, runbooks
```

Then tell the user:

> `.claude/settings.json` is seeded with arboretum's governance allow list, so `/health-check`, `/consolidate`, and `/finish` run without a permission prompt per script. For your project's *own* scripts (test runners, dev servers, lint commands), run `/fewer-permission-prompts` after a few working sessions — it scans transcript history and suggests commands that are safe to pre-approve.

### Step 9: Hand off to /architect

The next step is the architecture interview. Ask the user:

> "Ready to do the architecture interview now? `/architect` will walk through your project's purpose, actors, data, and constraints, then suggest an archetype and scaffold `ARCHITECTURE.md`. You can also defer this and run `/architect` later."

If yes, invoke `/architect`.

If no, tell the user: "Run `/architect` whenever you're ready. Until ARCHITECTURE.md exists, `/start` will work for small features but won't have an archetype to ground its routing decisions."

## Failure modes

- **`CLAUDE_PLUGIN_ROOT` unset** — the skill is being run outside a plugin context. The skill cannot proceed; ask the user to install the arboretum plugin and re-run.
- **`superpowers` not installed** — surfaced in Step 2 with install guidance. Stop and let the user remediate.
- **Target directory has a different VCS** — if `.hg`, `.svn`, or similar exists, skip the `git init` step and tell the user arboretum's git-related defaults assume git; they may need manual setup.
- **Permission errors during copy or chmod** — surface the specific path and let the user resolve (most often a permission issue on a directory above the target).

## Why this skill exists

Replaces `scripts/bootstrap-project.sh` so the framework distributes through the plugin marketplace rather than via `git clone` + `bash scripts/bootstrap-project.sh`. The skill is functionally equivalent to the script but runs inside Claude Code, can interview the user, and degrades gracefully when prerequisites are missing.
