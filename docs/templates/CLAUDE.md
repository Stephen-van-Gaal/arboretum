---
version: 1
---

# CLAUDE.md

> *Arboretum is choreography. Superpowers does the work.*

## Arboretum Contract

The canonical workflow contract is `ARBORETUM.md`. Follow `ARBORETUM.md ## COMMON` before applying tool-specific or project-specific instructions.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Everything-else work stops after `/design` for human review before `/build`.
Only verified `agent-ready` work and verified patch-lane briefs produced by `/start-bugfix` skip the review-before-build pause.

## Project Overview

<!-- 2-3 sentences. What does this project do, who uses it, what's the tech stack. -->

## Project Status

<!-- Current phase, what's in progress, what's next. -->

## Workflows

This project uses arboretum workflows. See `workflows/README.md` for details.

| Workflow | When to use |
|---|---|
| **build** | Adding, changing, fixing, refactoring, or documenting |
| **explore** | Need to learn before you can write a design spec |

### Development rules

- **Spec-first gate:** Code modification is allowed when files' `# owner:` headers point to a topic with either an existing governed spec at `docs/specs/<topic>.spec.md` (status `draft` or `active`) or an in-flight design spec at `docs/superpowers/specs/*-<topic>-design.md`. In the current general-release pipeline, `/design` may create or edit governed-spec intent/seam prose only through an approved Durable Document Change Set before `/build`; `/consolidate` reconciles generated/evidence sections and built-state updates at `/finish`. The state machine has three states (`draft / active / stale`); transitions are automatic via `/consolidate` and `/health-check`.
- **Ownership:** Every source file carries an owner marker on its first comment line, in the file's own comment syntax — `# owner: <spec>` for shell/Python/Ruby/YAML, `-- owner: <spec>` for SQL, `// owner: <spec>` for TypeScript/JavaScript/Go/Java/etc. Shell scripts keep the shebang on line 1 and the marker on line 2. **Generated files** carry a provenance banner their generator emits on every write — the owner line plus what generated them and when (`-- generated-by: <generator> — DO NOT EDIT` / `-- generated-at: <commit-or-timestamp>`) — so ownership survives regeneration; health-check recognizes the owner line anywhere in the leading comment block. Which languages are *enforced* (flagged when unowned) is set per repo via `source_languages:` in `.arboretum.yml`; `/health-check` nudges when it sees an undeclared recognized source type.
- **Permitted without spec change:** implementation-detail refactoring (preserves behaviour, tests pass), patch fixes (code didn't match spec), supplementary test additions.
- **Draft mode:** During early development when documents are `draft`, note ambiguities and continue rather than stopping. Stop only for contradictions or infeasibility.

## Testing

This project uses **test-driven development** (TDD). Red-green-refactor:

1. **Red:** Write a failing test that captures expected behaviour.
2. **Green:** Write the minimum code to make it pass.
3. **Refactor:** Clean up while keeping tests green.

Tests are tiered: unit (always) → contract (when shared definitions exist) → integration (when cross-spec dependencies exist). Declare "N/A — [reason]" for inapplicable tiers.

The project's test command and cost-class tiers are declared in `docs/specs/test-infrastructure.spec.md` (read by `/build`, `/finish`, and `/design` via `scripts/read-test-config.sh`). Run the default-safe suite with the declared `default-command`; opt-in `live`/`costly` tiers are run manually.

## Git Workflow

- **Branch protection:** Never commit directly to `main`. Feature branches: `feat/`, `fix/`, `docs/`, `chore/`.
- **Explicit staging:** Stage files by name. Never `git add -A` or `git add .`.
- **Commit messages:** Explain *why*, not *what*. Reference issues (e.g., "Closes #12").
- **One logical change per commit.**
- **Pull requests:** Use `/finish` for the full flow, or `/pr` directly.

## Skills

**Workflow:** `/start`, `/start-bugfix`, `/design`, `/finish`, `/cleanup`, `/reflect`

**Governance:** `/consolidate`, `/pr`, `/publish`

**Diagnostics:** `/health-check`

## Key Documents

| Document | Location | Status |
|---|---|---|
| **Architecture** | `docs/ARCHITECTURE.md` | <!-- draft / active / not yet created --> |
| **Specs** | `docs/specs/*.spec.md` | <!-- count and status --> |
| **Register** | `docs/REGISTER.md` | <!-- Layer 1+ --> |
| **Definitions** | `docs/definitions/` | <!-- Layer 1+, created when needed --> |

## Package Structure

```
<!-- Project directory layout. Update as structure evolves. -->
```

## Running Tests

```bash
<!-- Primary test command -->
```

## Key Design Decisions

<!-- Bullet list of the most important architectural decisions. -->

## Environment

<!-- Runtime requirements, external dependencies, setup instructions. -->
