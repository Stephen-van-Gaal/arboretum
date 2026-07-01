---
name: new-project
requires:
  - superpowers
---

# Workflow: New Project

Start from nothing. Build understanding iteratively through architecture decisions and spike-spec cycles before writing production code.

## When to use

You have an idea for a project but no code yet.

## Stages

```
/arboretum:init → /architect → [spike → /consolidate]* → build
```

(Projects without the plugin installed use `bin/arboretum bootstrap` in place of `/arboretum:init`; both produce the same scaffolding.)

## Artifact Flow

| Step | Reads | Produces | Location | Authority |
|---|---|---|---|---|
| 1. `/arboretum:init` | (empty dir), plugin templates | scaffolded project: `CLAUDE.md`, `docs/`, `workflows/`, hooks, configs | new project root | source |
| 2. `/architect` | user interview answers, principles | `ARCHITECTURE.md`, optional group docs, archetype match | `docs/ARCHITECTURE.md` | owning |
| 3a. Spike (per uncertainty) | architecture, problem space | working throwaway code | `spikes/` or branch | (throwaway) |
| 3b. `/consolidate` | spike outcome | governed spec at `draft` | `docs/specs/` | owning |
| 4. Build (per spec) | spec, plan | code + tests; `/finish` runs `/consolidate` to flip spec to `active` | source dirs, `docs/specs/` | source / owning |

### 1. Bootstrap — `/arboretum:init`

Create the project directory with arboretum structure. Sets up `CLAUDE.md`, hooks, skills, templates, and an empty `docs/specs/` directory.

**Input:** A project name and location.
**Output:** A bootstrapped project directory with git initialized.

### 2. Architecture — `/architect`

Interview to determine what you're building, who it's for, and how it should be organized. Matches your project to an architecture archetype and scaffolds `ARCHITECTURE.md`.

**Input:** Your answers to the architecture interview.
**Output:** `docs/ARCHITECTURE.md` with component boundaries and initial spec candidates identified.

### 3. Spike-spec cycle — repeat as needed

This is the core of the new-project workflow. For each area of uncertainty:

#### 3a. Spike

Write throwaway code to test assumptions. Spikes live in `spikes/` or a feature branch — they are never merged into production code.

**Skills:** `superpowers:systematic-debugging` (if investigating existing systems), or just hands-on experimentation.
**Output:** Knowledge about what works and what doesn't.

#### 3b. Consolidate — `/consolidate`

Capture what you learned into a governed spec. The spike taught you something — now write it down before you forget.

**Input:** What you learned from the spike.
**Output:** A new or updated spec in `docs/specs/` with status `draft`.

#### 3c. Check — do you know enough?

After each cycle, ask:
- Are the spec boundaries clear? Does each spec own a distinct piece of behaviour?
- Are shared data structures identified? Do specs that share concepts agree on definitions?
- Are there remaining unknowns that need another spike?

**If yes:** Continue to step 4.
**If no:** Return to step 3a with a new spike targeting the remaining uncertainty.

### 4. Build

Once specs are solid, implementation follows the feature workflow per-spec: plan, implement with TDD, finish. The spec status auto-flips `draft` → `active` via `/consolidate` after build.

**Skills:** `superpowers:writing-plans`, `superpowers:test-driven-development`, `superpowers:executing-plans`
**For each spec:** plan → build → `/finish`

## Exit criteria

- `ARCHITECTURE.md` exists and describes the system
- All planned specs exist with status `draft` or better
- At least one spec has been implemented end-to-end (validates the architecture)
