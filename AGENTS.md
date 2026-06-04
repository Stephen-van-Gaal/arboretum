# AGENTS.md — arboretum-dev

## Arboretum Contract

The canonical workflow contract is `ARBORETUM.md`. Follow `ARBORETUM.md ## COMMON` before applying tool-specific or project-specific instructions.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Everything-else work stops after `/design` for human review before `/build`.
Only verified `agent-ready` work skips the review-before-build pause.

## Project Overview

Arboretum is an organizational framework for building software with AI code agents. It gives domain experts a repeatable way to create projects that are well-organized, maintainable, and understandable — even when the human didn't write most of the code.

See `PRINCIPLES.md` for the nine principles that guide all design decisions. See `docs/ARCHITECTURE.md` for the full architecture.

**This is arboretum-dev** — the development repository. The public distribution is [arboretum](https://github.com/stvangaal/arboretum). Code flows one-way: arboretum-dev → arboretum via GitHub Actions sync on push to main.

## Project Status

Reorganizing — aligning architecture, workflows, skills, and templates with the four-pillar model (principles, workflows, skills, templates). The sample project (`examples/rule-flow-engine/`) is fully implemented.

## Four Pillars

Everything in arboretum falls into one of four categories:

- **Principles** — How software should be organized. Codified in `PRINCIPLES.md`.
- **Workflows** — Guide the user through best-practice sequences. Defined in `workflows/`.
- **Skills** — Discrete operations. Arboretum creates skills only when no adequate external skill exists.
- **Templates** — Standardized formats that skills produce and consume. In `docs/templates/`.

## Workflows

Five workflows cover the full development lifecycle. See `workflows/README.md` for details.

| Workflow | When to use |
|---|---|
| **new-project** | Starting from scratch |
| **build** | Adding, changing, fixing, refactoring, or documenting in an existing project |
| **explore** | Need to learn before you can write a spec |
| **publish** | Ready to share your project publicly |
| **retrofit** | Have an existing project you want to govern |

### Workflow stages at a glance

```
new-project      /arboretum:init -> /architect -> [spike -> /consolidate]* -> build
build            /start -> [/design] -> /build -> /finish -> /security-review -> /pr -> /land -> /cleanup -> /reflect
explore          /start -> spike -> document -> decide (-> build or -> another spike)
publish          /publish (review -> strip -> sync)
retrofit         assess -> bootstrap -> triage -> govern-one -> [expand]*
```

### How to use workflows

- **On change requests:** Use `/start` to detect the user's need and route to the appropriate workflow. Read the workflow's `## Stages` section (or `## Flow` if that workflow still uses the older heading) and follow its numbered steps.
- **Parse only workflow stage/flow sections** — skip diagrams (they're for human readers, not token consumption).
- **Delegate to skills** — each workflow step references a specific skill (superpowers or arboretum). Invoke that skill; don't reimplement the step.
- **`/consolidate` runs *after* build, not before.** In the current general-release pipeline the design spec output flows directly into planning; the governed spec is born from built state at `/finish` time, when `/consolidate` is auto-invoked. Do not run `/consolidate` between brainstorm and plan.
- **When in doubt about workflow stage:** Run `/health-check` to see where things stand.

### Skill families

Workflows invoke two families of skills:

**Superpowers** (development process): `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:verification-before-completion`, `superpowers:requesting-code-review`, `superpowers:finishing-a-development-branch`

**Arboretum** (governance): `/start`, `/design`, `/finish`, `/cleanup`, `/reflect`, `/health-check`

Arboretum does not replace superpowers — it sequences their invocation and ensures outputs feed into governed specs.

## Skills

User-facing skills live in `skills/` (the plugin location, where the loader resolves `<plugin-root>/skills/<name>/SKILL.md`). Dev-only skills (e.g. `dev-manage-workflows`) and archived skills stay at `.claude/skills/` and are excluded from the public sync. Each skill's frontmatter `description` is the authoritative source for what it does.

**Workflow (5):** `/start`, `/design`, `/finish`, `/cleanup`, `/reflect`

**Governance (6):** `/consolidate`, `/init-project`, `/architect`, `/pr`, `/publish`, `/receive-review`

**Continuity (1):** `/handoff` — queues a single GitHub issue as `next-up` so the next session boots oriented on it. Auto-invoked by `/finish`, `/cleanup`, `/reflect`. The boot banner surfaces whichever open issue carries the `next-up` label via `.claude/hooks/session-start.sh` (cached at `.arboretum/next-cache.json`, refreshed by `scripts/refresh-next-cache.sh` with a 1-hour TTL). Hard-fails with install/auth instructions if `gh` is missing. See issue #155.

**Diagnostics (1):** `/health-check`

**Layer 2 (1):** `/security-review`

### External skills (superpowers)

Arboretum wraps external skills at workflow transition points:

| External skill | Workflow stage |
|---|---|
| `superpowers:brainstorming` | Design |
| `superpowers:writing-plans` | Planning |
| `superpowers:test-driven-development` | Build |
| `superpowers:executing-plans` | Build |
| `superpowers:subagent-driven-development` | Build (alternative) |
| `superpowers:systematic-debugging` | Investigation |

## Development Rules

- **Spec-first gate:** Code modification is allowed when the changed files' `# owner:` headers point to a topic that has either an existing governed spec at `docs/specs/<topic>.spec.md` (status `draft` or `active`) **or** an in-flight design spec at `docs/superpowers/specs/*-<topic>-design.md` (the governed spec will be created by `/consolidate` at `/finish`). In the current general-release pipeline, governed specs are written **only** by `/consolidate` — no workflow step hand-authors a governed spec. If asked for a code change directly, identify the spec or design spec, offer to update it, and wait for approval. `/consolidate` flips `draft → active` automatically when reconciliation succeeds; `/health-check` flips `active → stale` when drift is detected. No manual promotion step.
- **Ownership:** Every source file includes `# owner: <spec-name>` as its first comment line. Shell scripts use shebang line 1 and `# owner: <spec-name>` line 2.
- **Permitted without spec change:** implementation-detail refactoring (preserves behaviour, tests pass), patch fixes (code didn't match spec), supplementary test additions.
- **Draft mode:** During early development when documents are `draft`, note ambiguities and continue rather than stopping. Stop only for contradictions or infeasibility.

### Schema-coupled scripts

Several scripts under `scripts/` are coupled by the format of files they share:

```
generate-register.sh ──▶ docs/REGISTER.md ──▶ health-check.sh (Checks 2/3)
                                          └─▶ validate-cross-refs.sh
                                          └─▶ .claude/hooks/session-start.sh
```

The `docs/REGISTER.md` table format is an implicit contract between these scripts. Issue #124 was caused by exactly this kind of coupling silently breaking: `generate-register.sh` was updated to emit a 4-column `Spec | Status | Owner | Owns` table, but `health-check.sh` kept parsing the older `spec.md | status | owns | depends` schema. Each script ran cleanly in isolation; the bug was only visible when the chain was exercised end to end.

**Rule:** when modifying any script under `scripts/` that produces output consumed elsewhere (`docs/REGISTER.md`, `contracts.yaml`, etc.), grep across all surfaces that might consume it before changing the format, and update them in the same change:

```bash
grep -rn "<output-filename>" scripts/ skills/ .claude/hooks/ docs/templates/
```

Test the round trip locally before pushing: regen the artifact, then run any consumer against it, and confirm clean output. A passing run of the modified script alone is necessary but not sufficient evidence the change is done.

The same discipline applies to any implicit contract embedded across multiple surfaces — including the spec-status enum, which currently has known active drift between the `draft/active/stale` enum used by scripts, hooks, and shipped skills, and the `draft/ready/in-progress/implemented` enum used by `workflows/README.md`, several spec frontmatters, and the `rule-flow-engine` example. Resolution is tracked in #398; until it's resolved, follow the convention of the surface you're editing rather than introducing a third option, and don't assume the script enum is the canonical one when editing workflow or template content.

## Testing

This project uses TDD. Red-green-refactor:

1. **Red:** Write a failing test that captures expected behaviour.
2. **Green:** Write the minimum code to make it pass.
3. **Refactor:** Clean up while keeping tests green.

Tests are tiered: unit (always) → contract (when shared definitions exist) → integration (when cross-spec dependencies exist). Declare "N/A — [reason]" for inapplicable tiers.

## Git Workflow

- **Branch protection:** Never commit directly to `main`. Feature branches with prefixes: `feat/`, `fix/`, `docs/`, `chore/`.
- **Explicit staging:** Stage files by name. Never `git add -A` or `git add .`.
- **Commit messages:** Explain *why*, not *what*. Reference issues (e.g., "Closes #12").
- **One logical change per commit.**
- **Pull requests:** Use `/finish` for the full flow, or `/pr` directly.
- **Copilot PR review: enabled.** After pushing, expect a review within ~15 minutes. Triage and respond to comments per the routine in the user's global `AGENTS.md`.

## Key Documents

| Document | Location |
|---|---|
| Principles | `PRINCIPLES.md` |
| Architecture | `docs/ARCHITECTURE.md` |
| Workflows | `workflows/` |
| Templates | `docs/templates/` |
| Specs | `docs/specs/` |
| Register | `docs/REGISTER.md` |
| Example project | `examples/rule-flow-engine/` |

## Two-Repo Model

| Repo | Purpose | Visibility |
|---|---|---|
| **arboretum-dev** (this repo) | Development: specs, plans, dev-only skills, tests | Private |
| **arboretum** | Distribution: clean framework for bootstrapping projects | Public |

Sync is one-way (dev → public) on push to main. Dev-only content (specs, plans, `dev-*` and `_archived` skills) is excluded. `CLAUDE.public.md` → `CLAUDE.md` and `README.public.md` → `README.md` in the public repo.

## Package Structure

```
arboretum-dev/
├── ARBORETUM.md                  # Canonical agent workflow contract
├── PRINCIPLES.md                 # Nine principles
├── AGENTS.md                     # This file — dev project instructions
├── CLAUDE.md                     # Dev Claude instructions
├── CLAUDE.public.md              # End-user CLAUDE.md (synced to public repo)
├── README.public.md              # End-user README.md (synced to public repo)
├── contracts.yaml                # Version pins (Layer 2)
├── workflows/                    # User-need-oriented workflow guides
│   ├── README.md                 # Master file — shared concepts, decision tree
│   ├── new-project.md            # Start from scratch
│   ├── build.md                  # Add, change, fix, refactor, or document
│   ├── explore.md                # Learn before you spec
│   ├── publish.md                # Share your project publicly
│   └── retrofit.md               # Govern an existing codebase
├── bin/                          # CLI scripts
│   ├── arboretum                 # CLI entry point (bootstrap, update)
│   └── arboretum-graduate        # Manual sync to public repo
├── scripts/                      # Governance automation scripts
├── .claude/
│   ├── settings.json             # Hook configuration
│   ├── hooks/                    # Event-driven automation
│   └── skills/                   # Slash skills
├── .github/
│   └── workflows/
│       └── sync-public.yml       # Automatic sync to public repo
├── docs/
│   ├── ARCHITECTURE.md           # System architecture
│   ├── REGISTER.md               # File ownership index
│   ├── templates/                # Document templates
│   ├── specs/                    # Spec files (dev-only)
│   ├── plans/                    # Ephemeral plans (dev-only)
│   └── superpowers/              # Design-phase docs (dev-only)
└── examples/
    └── rule-flow-engine/         # Fully governed sample project
```

## Environment

Bash for governance scripts. No external runtime dependencies for the framework itself. Sample projects may have their own requirements (e.g., the rule-flow-engine example uses Node.js/TypeScript).
