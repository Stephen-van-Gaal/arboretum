---
name: reflect
owner: workflow-unification
description: "Post-cycle reflection — surfaces agent observations on workflow, process, and capability patterns; captures follow-ups and next-up. Replaces the prior user-interview format."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - AskUserQuestion
layer: 0
---

# Reflect

The end of a ship cycle, with the agent's freshly-fired build context still available. The agent surfaces observations the user wouldn't have time to reconstruct; the user reacts. The asymmetry of attention is the central design — see WS1 design D7 (`docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md`).

## When to use

- After a PR merges (suggested by `/cleanup`)
- After a spike completes
- After resolving an incident or debugging session
- Whenever the user wants to capture what they learned

## Procedure

### Step 1: Set context

Gather context about what just happened. Check:

```bash
# Recent merge?
git log --oneline -5

# What branch was this?
gh pr list --state merged --limit 1 --json title,number,body
```

Summarize briefly: "You just merged PR #N: <title>. Let's capture what you learned."

If there's no recent merge (user invoked manually), ask: "What were you just working on?"

### Step 2: Surface agent observations + abbreviated reaction

The *agent* has the build-cycle context the user doesn't have time to reconstruct. The agent surfaces; the user reacts.

#### Step 2a — Agent-surfaced observation report (primary, always present)

Produce a structured report grouped under three categories. Aim for **3–5 observations total** across all three categories — not 3–5 per category. Empty categories are stated as such ("Workflow: nothing notable this cycle"), never padded.

- **Workflow** — what was friction-y this cycle (skill/tool round-trips, repeated workarounds, places the agent had to guess at convention).
- **Process** — patterns worth a durable update (skill behavior worth changing, a missing convention, a CLAUDE.md rule that fired or should have fired).
- **Capability** — patterns in the user's work — strengths to lean into, gaps to consider. Honest, non-performative; the agent is the one place a critical observation lands without social cost.

Source material: the conversation history (especially the user's redirects and corrections), the commits on this branch, the PR review comments, any explicit signals in `/handoff` summaries.

Render as a single Markdown block under the heading `## Observations`. Save to the same destinations Step 3 lists (memory or learning log) once the user has reacted.

#### Step 2b — Abbreviated reaction prompt (secondary, skippable)

After the observations, ask one consolidated question via `AskUserQuestion`:

> *"Anything to add, push back on, or want me to capture as a follow-up?"*

Free-text response. The user can skip with no consequence — the observation report stands on its own as the durable output of this skill.

#### Step 2c — Follow-up capture (conditional)

If the user names follow-ups in their reaction, **or** if the agent's own observations include a follow-up candidate (a workflow-friction or process pattern worth filing), offer to invoke `/roadmap agent-prep` for each. Single-pass — propose all candidates at once, capture the user's yes/no per item, file the ones they accept. No nagging on declines.

#### Step 2d — Q5: next-up (preserved, mandatory)

Ask exactly as before: "Which issue should be queued as `next-up` for the next session?" — request an issue number (or 'skip'). If the user gives a number, invoke `/handoff <N> --completed`. The `/handoff` skill is the canonical writer — it manages the GitHub `next-up` label and refreshes the local cache; the `--completed` flag keeps it in completion mode (label only — no note draft, no unchecked-box enforcement). This skill does not call `gh` directly for next-up label or cache writes (Step 1 still uses `gh pr list` for read-only context).

If the user skips, **no `next-up` is queued** — declining the reflection is a signal the session is *done*, not that another one is queued. This is also the canonical handoff invocation in the ship tail (D8) — `/finish` and `/cleanup` no longer prompt for next-up separately.

### Step 3: Save insights

If the user shared anything worth keeping, offer to save it. Two possible destinations:

**Memory** (for cross-session lessons):
If the insight is about how they work, how the project works, or a preference that should carry forward, save it as a memory file:

```
Memory file: feedback_<topic>.md or project_<topic>.md
Type: feedback (for process/approach lessons) or project (for domain/codebase lessons)
```

**Learning log** (for personal reference):
If the insight is more reflective or personal, append to `docs/learning-log.md` (create if it doesn't exist). Format:

```markdown
## YYYY-MM-DD — <brief topic>

**Context:** <what was being worked on>
**Insight:** <what was learned>
```

Ask the user which destination feels right, or suggest based on the content. Don't force either — if the user says "nothing worth saving," that's fine. The reflection itself has value.

### Step 4: Close

Keep it brief:

> "Good reflection. Ready for the next task?"

## Important

- **This is not a gate.** It's a prompt. If the user doesn't want to reflect, respect that immediately — but the observation report (Step 2a) is the agent's contribution and lands regardless of whether the user reacts.
- **Keep it lightweight.** 3–5 observations total across all three categories, one reaction prompt, optional follow-up capture, the mandatory Q5. No forms, no required fields, no ceremony.
- **The agent surfaces; the user reacts.** The asymmetry of attention (D7) is the design — the agent has the build-cycle context the user does not, so the burden of noticing lands with the agent, not the user.
- **SRP:** This skill handles reflection only. `/cleanup` handles housekeeping. `/handoff` manages the GitHub `next-up` label. They are separate responsibilities — Q5 delegates to `/handoff` rather than duplicating the GH-write logic, and `/reflect` is the single canonical handoff invocation in the ship tail (D8).
- **Complementary to `explanatory-output-style`.** That plugin surfaces inline insights during every response (per-response cadence); this skill is the per-cycle aggregate surface (post-ship cadence). The two are complementary; no code reuse between them.

$ARGUMENTS
