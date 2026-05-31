---
name: init-project
owner: arboretum-as-plugin
description: Initialize a new project with spec-driven development infrastructure — creates directory structure, copies templates, sets up hooks. Use when starting a new project or adding spec governance to an existing one.
disable-model-invocation: false
allowed-tools: Bash(bash scripts/bootstrap-project.sh *), Read, Write
argument-hint: [target-directory]
layer: 0
---

# Initialize Spec-Driven Project

Bootstrap a new project (or add spec governance to an existing one) using the spec-driven development workflow.

## Procedure

### 1. Determine target

If `$ARGUMENTS` is provided, use it as the target directory. Otherwise, ask the user where to initialize.

### 2. Check existing state

Before running the bootstrap script, check what already exists in the target:
- Does `PRINCIPLES.md` already exist?
- Does `workflows/` already exist?
- Does `docs/` already exist?
- Does `CLAUDE.md` already exist?
- Does `.claude/` already exist?

If any of these exist, inform the user that the bootstrap script is idempotent (won't overwrite existing files) and ask if they want to proceed.

### 3. Select layer

Ask the user about their project's scale:
- **"Just me and AI, a few specs"** → Layer 0 (foundation)
- **"Growing project, 3+ specs, shared data"** → Layer 1 (structure)
- **"Team project, CI, multiple developers"** → Layer 2 (governance)

If unsure, default to Layer 0. The session-start hook will suggest upgrades when the project outgrows its layer.

### 4. Run bootstrap

Run `bash scripts/bootstrap-project.sh $ARGUMENTS` (or the target directory).

**Layer filtering:** Only copy skills where the skill's `layer` field in its SKILL.md frontmatter is <= the selected project layer. For example, a Layer 0 project receives only layer-0 skills; a Layer 1 project receives layer-0 and layer-1 skills. The bootstrap script handles this automatically via the `--layer` flag. If running manually, check each skill's SKILL.md for `layer: N` and skip skills above the target layer.

Create `.arboretum.yml` in the target directory with the selected layer:
```yaml
# Arboretum project configuration
# layer: 0 = foundation, 1 = structure, 2 = governance
layer: <selected-layer>
# Tracker/repo backend. Default: github. Future: azure-devops.
backend: github
```

Present what was created:
- Directory structure
- Template files copied
- Hooks installed
- Layer configuration
- Any files that were skipped (already existed)

### 5. Architecture interview

Invoke the `/architect` skill to guide the user through an architecture interview. This determines the project shape, matches an archetype, and scaffolds `ARCHITECTURE.md` and group documents in `docs/groups/`.

If the user declines or wants to skip, proceed without — the architecture can be set up later by running `/architect` standalone.

### 6. Guide first steps

After bootstrapping, guide the user based on layer:

**Layer 0:** "Start with the feature workflow: write your first spec in `docs/specs/` using the spec template. That's all you need to start."

**Layer 1:** Guide through creation order:
1. **ARCHITECTURE.md** — created by `/architect` in the previous step
2. **Shared definitions** — create in `docs/definitions/` if specs share data structures
3. **First spec** — write in `docs/specs/` using `docs/templates/spec.md`

**Layer 2:** Same as Layer 1, plus:
4. **contracts.yaml** — will be populated as specs declare dependencies
5. **CI setup** — health-check and contract tests in CI pipeline

### 7. Verify

Run `bash scripts/health-check.sh` against the new project to confirm the structure is valid.

$ARGUMENTS
