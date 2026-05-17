---
name: design
owner: workflow-management
description: Wrapper skill that orchestrates the design phase — runs external brainstorming to produce a design spec. On Path A, also consolidates into a governed spec at status `draft`; on Path B, exits to planning with the design spec as in-flight authority (governed spec is born later at `/finish`). Use at the start of planned work.
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
argument-hint: "[path/to/design-spec.md]"
layer: 0
---

# Design

Orchestrates the transition from idea to implementable governed spec. This is a wrapper that coordinates external design skills with arboretum's governance.

## When to use

- Starting planned work (user knows what they want to build)
- After `/start` routes to the planned path
- When the user says "let's design this" or "let's spec this out"

## Procedure

### Step 0: Determine path — A or B?

Ask the user (or determine from context) which governance path applies:

- **Path A (spec-first):** the user knows what they want to build. Output is the governed spec at `docs/specs/<topic>.spec.md`, status `draft`. After approval the workflow goes to `/consolidate` (which here just creates the governed spec from the design discussion), then plan, then build.
- **Path B (design-first):** the user is exploring or the design is still emerging. Output is the design spec at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. The governed spec is created later by `/consolidate` after build.

The handoffs differ:
- **Path A handoff:** design discussion → `/consolidate` to create governed spec at status `draft` → plan → build → `/consolidate` (regenerate; status flips to `active`) → `/finish`.
- **Path B handoff:** design spec written → plan → build → `/consolidate` (creates governed spec at name = design topic, status `active`) → `/finish`.

Default to Path A unless the user explicitly says they want to explore.

### Step 1: Check for existing design work

If `$ARGUMENTS` is provided, treat it as a path to an existing superpowers design spec:
1. Read the file
2. Confirm with the user: "Found design spec at `<path>`. Consolidate this into a governed spec?"
3. If confirmed, skip to Step 3 (consolidate).

Otherwise, check for unconsolidated design specs:
```bash
ls docs/superpowers/specs/*.md 2>/dev/null
```

If any exist, present them:
> "Found existing design specs:
> 1. `docs/superpowers/specs/<file1>.md` — <first heading>
> 2. `docs/superpowers/specs/<file2>.md` — <first heading>
>
> Consolidate one of these, or start a new design?"

### Step 1b: Survey existing specs

Before starting the brainstorming phase, read existing specs in `docs/specs/` and `docs/ARCHITECTURE.md` to surface governed code that may be relevant to the design topic. This prevents designing something that overlaps with existing work.

### Step 2: Brainstorm (wrapped delegation to brainstorm capability)

If no existing design spec is being used, initiate the brainstorming process. This step wraps the external brainstorm capability with three responsibilities — *brief*, *capture user contributions*, *verify* — per `docs/ARCHITECTURE.md ## Wrapped delegation pattern`.

#### 2a. Brief

Before invoking brainstorming, gather the project context the external skill cannot infer:

- **Spec structure** — read `docs/templates/spec.md` so the design spec's structure aligns with what `/consolidate` will later harvest from.
- **Related governed specs** — list specs from `docs/specs/` that touch the topic; brainstorming should read these to avoid duplicating existing behaviour.
- **Naming and path conventions** — Path B output goes to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`; Path A consolidates to `docs/specs/<topic>.spec.md`.
- **Path-aware exit** — tell brainstorming the chosen path so its output is named/located accordingly.

Hand these to brainstorming as a structured prompt. The brief turns generic-correct brainstorming into project-correct brainstorming.

#### 2b. Capture user contributions

Before brainstorming starts, ask the user (via `AskUserQuestion`) for domain knowledge brainstorming cannot infer from the codebase:

> "Before brainstorming, are there domain constraints, stakeholders, or known unknowns I should hand over? For example: regulatory rules that scope behaviour, downstream consumers that lock interfaces, prior approaches that didn't work."

Capture the response and include it in the brief. If the user has nothing to add, proceed.

#### 2c. Invoke brainstorming

Invoke the **brainstorm** capability (currently provided by `superpowers:brainstorming`) with the brief plus user contributions. If the provider is not available, conduct the design conversation directly using the same brief.

The brainstorm process will:
- Ask clarifying questions (informed by the brief and user contributions)
- Propose approaches
- Present a design for approval
- Write a design spec to the path specified in the brief

#### 2d. Verify output

After brainstorming returns, before exiting Step 2:

- **Path check** — design spec landed at the expected location (Path A → `docs/specs/...`, Path B → `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`).
- **Structure check** — required sections present (Purpose, Behaviour, key decisions). Path A specs follow the spec template; Path B design specs follow superpowers' design-spec format.
- **Contribution check** — if the user supplied domain constraints in 2b, confirm they are reflected in the design spec (either as Behaviour clauses, decisions, or open questions).

If any check fails, surface the gap to the user and offer to amend before continuing.

#### 2e. Path-aware exit

When verification passes:
- **Path B (design-first):** the design spec is the output. Exit to planning — `/consolidate` will run later at `/finish` and produce the governed spec from built state. Do not call `/consolidate` here.
- **Path A (spec-first):** consolidate the design spec into the governed spec now (Step 3) so it can be reviewed before planning. The governed spec lands at status `draft`.

### Step 3: Consolidate into governed spec

Run `/consolidate` with the design spec path:

1. Invoke the consolidate skill, pointing it at the design spec produced in Step 2 (or provided via `$ARGUMENTS`).
2. The consolidate skill will:
   - Harvest content from the design spec
   - Create or update governed specs in `docs/specs/`
   - Update the register
   - Set status based on workflow stage: Path A pre-build consolidation creates the governed spec at `draft` (no code yet); Path B post-build reconciliation against existing code auto-flips `draft → active` when consolidation succeeds (no separate promotion step)
   - **Retain** the design spec — it is a permanent historical record

3. After consolidation completes, confirm the result:
> "Governed spec created: `docs/specs/<name>.spec.md` (status: `draft` for Path A pre-build, or `active` for Path B post-build).
> Ready to plan the implementation?"

### Step 4: Transition to planning (wrapped delegation to plan capability)

Once the governed spec exists (Path A) or the design spec is approved (Path B), invoke the plan capability with the same brief / contribute / verify wrapping.

#### 4a. Brief

Hand the plan capability the project context it needs:

- **Workflow stage map** — read `workflows/feature.md` (or the active workflow). The plan must respect Build → `/finish` → `/consolidate` → `/cleanup`, not assume the spec is `active` before code is written. Path B plans in particular must understand that the governed spec is *born* at `/finish`, not pre-build.
- **Test taxonomy** — `CLAUDE.md ## Testing` defines the project's tiers (unit, contract, integration, domain). Plan steps should pair code work with the appropriate test tier.
- **Consolidate-last lifecycle** — the plan should not include a "promote spec to active" step; that flips automatically.
- **Plan location** — arboretum plans live in `docs/plans/YYYY-MM-DD-<topic>.md` (per `CLAUDE.md` package structure). State this explicitly when invoking the plan capability: `superpowers:writing-plans` otherwise defaults to `docs/superpowers/plans/`, which is not arboretum's convention.

#### 4b. Capture user contributions

Ask the user:

> "Before I plan: are there checkpoints where you want me to pause for review? For example: after the riskiest step, after the first end-to-end pass, before any irreversible operation."

Include the response in the brief.

#### 4c. Invoke plan capability

Suggest: "The spec is ready. Want to create an implementation plan?"

If yes, invoke the **plan** capability (currently provided by `superpowers:writing-plans`), using the governed spec as input — not the design spec — plus the brief and user contributions. If the provider is not available, create the plan directly following the project's plan template.

#### 4d. Verify output

After the plan returns:

- **Tier match** — each plan step has test expectations naming the appropriate tier from the project's taxonomy.
- **Checkpoint match** — if the user supplied review checkpoints in 4b, the plan includes them as explicit pause points.
- **Lifecycle match** — the plan ends at "create PR via `/finish`" and does not pre-flip spec status.
- **Location match** — the plan was written to `docs/plans/`, not the `superpowers:writing-plans` default `docs/superpowers/plans/`. If it landed in the wrong place, move it.

If any check fails, ask the plan capability to amend (or amend directly).

## Important

- This skill is the **conductor** for the design phase. It doesn't replace brainstorming — it ensures the output lands in the right place (governed specs, not just design docs).
- The critical value is the **path-aware exit**. On Path A the wrapper consolidates into a governed spec for review before planning; on Path B it exits to planning with the design spec as the in-flight authority (the governed spec is born at `/finish`). Both paths are gate-compliant — the spec-first gate accepts either a governed spec (`draft`/`active`) or a design spec for the topic.
- If the user wants to skip brainstorming and write a spec directly, they can create one from `docs/templates/spec.md`.
- If the user is on the exploratory path and has already explored, skip brainstorming — go straight to consolidation (Step 3).

$ARGUMENTS
