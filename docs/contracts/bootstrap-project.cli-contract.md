---
script: scripts/bootstrap-project.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/init-project
  - type: script
    name: bin/arboretum (bootstrap subcommand)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/bootstrap-project.sh`

## Surface

Idempotent project scaffolder. Given a target directory and an optional project name, creates the full arboretum directory structure, copies principles, workflow files, doc templates, reserved specs, Claude Code hooks, git hooks, and skill directories into the target, generates `.arboretum.yml`, `CLAUDE.md`, `contracts.yaml`, `.publishignore`, and `.claude/settings.json`, initialises a git repository if one does not already exist, and configures `core.hooksPath = .githooks`. Skips any file that already exists at the destination — it will not overwrite. The `--layer N` flag gates skill and hook installation: only skills whose SKILL.md frontmatter declares `layer: <= N` are copied, and the `pre-commit-branch-check.sh` hook (Layer 2+) is omitted when `N < 2`. Invoked by the `/init-project` skill and by the `bin/arboretum bootstrap` CLI entry point; developers may also run it directly.

## Protocol

### Arguments

```
bootstrap-project.sh [--layer N] <target-directory> [project-name]
```

- `--layer N` *(optional flag, before positional args)* — integer maximum layer. Only skills with `layer <= N` in their SKILL.md are copied. Default `99` (copy all layers). The flag value must be an integer; missing value causes a usage error (exit 1).
- `-h` / `--help` *(optional flag)* — print usage and exit 1.
- `<target-directory>` *(required, positional $1 after flag parsing)* — path to the directory to bootstrap. Created with `mkdir -p` if it does not exist.
- `[project-name]` *(optional, positional $2)* — human-readable project name used when rendering `CLAUDE.md` from the template. Defaults to the basename of `<target-directory>`.

Flag parsing is performed before positional arguments: flags (`--layer`, `-h`/`--help`) must appear before `<target-directory>`.

### Exit codes

- `0` — bootstrap completed (all idempotency skips are still success).
- `1` — invocation error. One of: `<target-directory>` not supplied, `--layer` flag present but value missing, `-h`/`--help` requested. Usage message printed to stdout.
- `1` — source-file not found. One of the required source files (`docs/templates/spec.md`, `docs/templates/PRINCIPLES.md`, `workflows/README.md`) is absent from the arboretum installation. Error message printed to stdout, instructing the user to run from the arboretum project directory.

No other exit codes. When `set -euo pipefail` causes an unexpected subcommand failure the shell may propagate that subcommand's exit code, but such cases are not part of the documented contract.

### Side effects

- **Directories created** (via `mkdir -p`, idempotent): `<target>/docs/`, `<target>/docs/definitions/`, `<target>/docs/specs/`, `<target>/docs/reference/`, `<target>/docs/plans/`, `<target>/docs/templates/`, `<target>/workflows/`, `<target>/.claude/`, `<target>/.claude/hooks/`, `<target>/.claude/skills/<skill-name>/` (one per copied skill), `<target>/.githooks/`.
- **Files written** (copy-if-missing, idempotent — existing files are never overwritten): `<target>/PRINCIPLES.md`, `<target>/workflows/*.md`, `<target>/docs/templates/*`, `<target>/docs/specs/test-infrastructure.spec.md` (if template present), `<target>/docs/specs/project-infrastructure.spec.md` (if template present), `<target>/.claude/hooks/session-start.sh` (always), `<target>/.claude/hooks/pre-commit-branch-check.sh` (when `MAX_LAYER >= 2`), `<target>/.claude/settings.json` (full or layer-0/1 variant), `<target>/.githooks/*`, `<target>/.claude/skills/<name>/SKILL.md` (per skill, layer-filtered), `<target>/contracts.yaml`, `<target>/.publishignore`.
- **Files generated** (written only when absent): `<target>/CLAUDE.md` (rendered from template with project name substituted), `<target>/.arboretum.yml` (hardcoded `layer: 0` and `backend: github` defaults).
- **Git operations**: `git init -q` in `<target>` (only when `.git` absent); `git config core.hooksPath .githooks` in `<target>` (only when not already set to `.githooks`).
- **chmod**: `chmod +x <target>/.claude/hooks/*.sh` and `chmod +x <target>/.githooks/*` — makes all copied shell scripts executable.
- **No network calls.**

## Test surface

- **CLI-1: Positional-arg and exit-code contract.** Invoking with no arguments exits 1 (usage error) — pinned (CLI-1a/CLI-1b). Invoking with a valid target directory is *intended* to exit 0, but currently aborts non-zero at the `cp`-on-directory bug (#420); that exit-0 invariant is **SKIP'd** (CLI-1c) until the fix.
- **CLI-2: Idempotent directory creation.** Running bootstrap twice against the same target preserves the directories created before the abort (pinned). The "exits 0 both times" invariant is **SKIP'd** pending #420 (the second run also aborts at the same `cp` step). No files are overwritten on the second run.
- **CLI-3: Core directory structure created.** After a successful run, the target contains at minimum `docs/`, `docs/specs/`, `docs/templates/`, `workflows/`, `.claude/hooks/`, `.githooks/`. Pinned in CLI-3.
- **CLI-4: CLAUDE.md rendered with project name.** When `[project-name]` is supplied, `CLAUDE.md` in the target contains that project name. When omitted, the target directory basename is used. Pinned in CLI-4.
- **CLI-5: .arboretum.yml created.** A fresh run creates `<target>/.arboretum.yml` containing `layer: 0` and `backend: github`. Pinned in CLI-5.
- **CLI-6: Layer filter — pre-commit hook gated at Layer 2.** With `--layer 1`, `pre-commit-branch-check.sh` is NOT copied to `.claude/hooks/`. With `--layer 2`, it IS copied. Pinned in CLI-6.
- **CLI-7: Layer filter — settings.json variant.** With `--layer 1`, `settings.json` contains only a `SessionStart` entry and no `PreToolUse` section. With `--layer 2` (or default), `settings.json` is the full settings copied from the arboretum installation. Pinned in CLI-7.
- **CLI-8: Git repository initialised.** After a run against a directory that is not yet a git repo, `.git/` exists in the target and `git config core.hooksPath` returns `.githooks`. Pinned in CLI-8.
- **CLI-9: Source-files-not-found guard.** When run outside an arboretum tree (the `docs/templates` dir is absent), the script exits non-zero with a missing-source diagnostic (`No such file or directory`). Note: under `set -euo pipefail` the `realpath "$SCRIPT_DIR/../docs/templates"` call aborts *before* the explicit "Verify source files exist" guard, so the friendly "run this script from the arboretum repo" message is not reached on a missing templates dir — a known limitation in the #420 family. Pinned in CLI-9 (non-zero exit + missing-source diagnostic).

## Versioning

- **1.0** — initial contract (2026-05-30).
