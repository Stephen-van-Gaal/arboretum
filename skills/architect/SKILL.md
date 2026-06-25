---
name: architect
owner: workflow-unification
scope: plugin-only
description: "Interview the user to determine project shape, match to an architecture archetype, surface essential decisions, recommend spikes, and scaffold ARCHITECTURE.md and group documents. Standalone or called by /init-project."
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - AskUserQuestion
layer: 0
---

# Architect

Interview the user to understand their project's shape, match it to an architecture archetype, surface essential decisions early, recommend spikes for high-risk areas, and scaffold governed documents.

## When to invoke

- **Standalone:** user runs `/architect` directly
- **Via `/init-project`:** called as a step after project bootstrapping
- **Two modes:** greenfield (no existing code) and existing project (has code or specs)

## Mode detection

Check for signals of an existing project:

1. Does `ARCHITECTURE.md` or `docs/ARCHITECTURE.md` exist?
2. Are there specs in `docs/specs/`?
3. Are there source files (beyond config and docs)?

If any of these exist, use **Existing Project Mode**. Otherwise, use **Greenfield Mode**.

---

## Procedure — Greenfield Mode

### Step 1: Interview

Ask about the project through guided conversation. **One question at a time.** After each answer, confirm understanding before moving on.

Cover these areas through guided conversation. **One question at a time.** The order below is a guide — follow the conversation naturally, but ensure all areas are covered before moving to archetype matching.

#### Purpose and scope

1. **What does the system do?** — purpose, domain, the core problem it solves
2. **What is NOT in scope?** — what are you explicitly deferring or excluding? Where does "version 1" end? Domain experts tend to see everything as important; this question forces prioritization early.

#### Actors and boundaries

3. **Who or what uses it?** — human users, other systems, APIs, scheduled jobs. What roles or personas interact with the system, and what does each one need?
4. **Where does the system end?** — what's inside vs. outside? For everything outside (databases, APIs, third-party services, human processes), how does data cross the boundary? This defines your integration surfaces.

#### Data and flow

5. **Where does the important data live, and what shape is it?** — domain experts often understand their data deeply. Draw this out: what are the core entities, how do they relate, what transforms them? Data gravity often dictates architecture more than any other factor.
6. **How does data flow through the system?** — linear stages, request/response, hub-and-spoke, event-driven. This is the primary signal for archetype matching.

#### Risk and uncertainty

7. **What's the hardest part?** — what are you least sure about? What might not work as expected? This directly feeds spike recommendations. If the answer is "nothing," probe deeper — the riskiest parts are often the ones that feel obvious until you try to build them.
8. **What happens when things go wrong?** — not an exhaustive failure catalog, but the key failure modes. Domain experts know their domain's failure modes; they just need to be prompted to think about them in a system context. (e.g., "What if the upstream data is malformed? What if a step fails halfway through?")

#### Scale

9. **What's the expected scale?** — handful of specs or dozens. This influences governance layer recommendations.

**Use simple ASCII diagrams throughout the interview to confirm understanding.** After learning about data flow, sketch it and ask "does this look right?" For example:

```
Based on what you've described, here's what I'm seeing:

  [EHR system] → parse → classify → generate → [billing system]

Does this capture the flow, or am I missing something?
```

### Step 2: Match archetype

Read all `.md` files in the `archetypes/` subdirectory of this skill's directory (`${CLAUDE_PLUGIN_ROOT}/skills/architect/archetypes/` when running from the installed plugin, or `skills/architect/archetypes/` when running from arboretum-dev's working tree). For each archetype file, review its **Recognition Signals** section — keywords, data flow pattern, and shape.

Compare the interview signals holistically against each archetype. Don't require exact keyword matches — look for pattern alignment:
- Does the data flow pattern match?
- Does the grouping axis make sense for this project?
- Does the boundary pattern reflect what the user described?

If a match is found, present the archetype's diagram template **applied to THIS project** — not the generic example. Show the user's actual system components in the archetype's diagram shape.

If no clear match, take the **escape hatch** (see below).

### Step 3: Surface essentials

Present the essentials from the matched archetype (from its **Generic Essentials** section), applied to this specific project. Add any project-specific essentials discovered during the interview.

Categorize by cost:

- **HIGH COST** — expensive to change later. These are structural decisions baked into every spec.
- **MODERATE** — causes pain but is recoverable. Worth getting right, but not catastrophic if wrong.
- **EASY TO MISS** — project-specific concerns surfaced from the interview that don't appear in the generic archetype.

### Step 4: Recommend spikes

For each **HIGH COST** essential, recommend a concrete spike using the archetype's **Spike Triggers** section as a template. Each spike recommendation should state:

- **What to spike** — a concrete, time-boxed experiment
- **What question it answers** — the specific uncertainty being resolved
- **How to know the spike succeeded** — observable criteria

### Step 5: Present summary for approval

Show the full architecture summary in one block:

1. **Project name and description**
2. **Matched archetype** (and why it was chosen)
3. **Spec groups** — with purposes and boundaries
4. **Shared definitions** — categorized by type if pipeline (flowing, config, reference)
5. **Essentials** — with cost ratings
6. **Spike recommendations**

**Wait for user confirmation before generating any files.** Ask: "Does this look right? I'll generate ARCHITECTURE.md and group stubs once you approve."

### Step 6: Scaffold documents

After user approval, generate:

**`ARCHITECTURE.md`** — use the matched archetype's "Architecture.md Template Sections" as the structure. Fill with project-specific details from the interview. Include the canonical diagram with this project's actual components.

**`docs/groups/<name>.md`** — one stub per spec group. Use `docs/templates/group.md` as the base structure, and the archetype's "Group Document Template Sections" for content guidance. Each group document gets:
- `owner: architecture` in frontmatter
- `name:` as lowercase-hyphenated (e.g., `ingestion-routing`)
- Boundaries filled in from the interview
- Member specs table left empty (specs don't exist yet)

---

## Procedure — Existing Project Mode

### Step 1: Assess current state

Read existing project artifacts to build understanding. Prefer bounded reads over whole-file reads — use `bash scripts/explore-doc.sh <doc>` to discover headings, then `bash scripts/read-doc-section.sh <doc> "<heading>"` for the relevant section(s); fall back to a whole-file read only when discovery is insufficient:
- `ARCHITECTURE.md` or `docs/ARCHITECTURE.md` — scan the sections relevant to the assessment (e.g. `§1 — Product JTBD`, `§5 — Component Jobs`)
- `docs/REGISTER.md` — the `Spec Index` section (`bash scripts/read-doc-section.sh docs/REGISTER.md "Spec Index"`)
- Specs in `docs/specs/`
- Source files (scan directory structure and key files)

Summarize what you found before starting the interview.

### Step 2: Informed interview

Same areas as greenfield (purpose/scope, actors/boundaries, data/flow, risk/uncertainty, scale), but **Claude proposes answers from what it read**. The user confirms or corrects.

Example: "Based on your code, this looks like a pipeline that transforms clinical documents into billing claims. Is that right?"

This is faster for the user and validates Claude's understanding. Pay special attention to scope and boundaries — existing projects often have implicit scope that needs to be made explicit.

### Step 3: Match archetype

Same as greenfield, but validate against existing structure. If the code structure doesn't match the archetype, flag it explicitly:

> "Your code looks like a pipeline but your specs are grouped by feature. Want to restructure, or keep the current organization?"

### Step 4: Surface essentials

Same as greenfield, but flag which essentials are **already violated** in existing code:

> "Your stages share imports — spec independence needs attention."

### Step 5: Recommend spikes

Only recommend spikes for essentials **not yet validated** by existing tests or working code. If a spike's question is already answered by production behaviour, skip it.

### Step 6: Present summary for approval

Same approval gate as greenfield.

### Step 7: Generate or update documents

Reconcile the archetype template with any existing `ARCHITECTURE.md` — don't overwrite existing decisions or content. Create any missing group documents.

---

## No-Match Escape Hatch

If interview signals don't clearly match any archetype:

1. **Say so explicitly:** "Your project doesn't clearly fit any of my current archetypes (pipeline, library, etc.)."
2. **Offer a minimal architecture:**
   - System-level description
   - Flat spec list (no spec group layer)
   - No group documents generated
3. **Set expectations:** "As your project grows, patterns will emerge. Run `/architect` again when you have 5+ specs and the grouping axis should be clearer."
4. **Let the user proceed** — this skill is guidance, not a gate.

---

## Key principles

- **One question at a time** during the interview. Don't dump all five questions at once.
- **Use ASCII diagrams** to confirm understanding at each stage.
- **Present the archetype applied to THIS project**, not the generic example from the archetype file.
- **The user must approve the summary** before any files are generated.
- **This skill is guidance, not a gate.** If the user wants to skip the interview, skip parts, or override the archetype match, let them.

$ARGUMENTS
