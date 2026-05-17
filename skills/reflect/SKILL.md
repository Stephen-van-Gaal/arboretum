---
name: reflect
owner: workflow-management
description: "Lightweight learning interview at natural stopping points — post-merge, post-spike, or post-incident. Captures lessons while context is fresh. Suggested by /cleanup but never bundled into it."
allowed-tools:
  - Read
  - Write
  - Edit
  - AskUserQuestion
layer: 0
---

# Reflect

A short, prompted interview to extract lessons at natural stopping points. The value isn't the log — it's building the habit of pausing to reflect while the context is fresh.

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

### Step 2: Interview

Ask these questions **one at a time**. Keep it conversational, not formal. Skip any that don't apply.

1. **What surprised you?** — anything that didn't work the way you expected, or was easier/harder than anticipated. Surprises are the highest-value lessons because they reveal gaps between your mental model and reality.

2. **What would you do differently?** — not regret, but informed hindsight. If you started this task over with what you know now, what would change? This might be a different approach, a different sequence, or a different scope.

3. **What should you remember for next time?** — a concrete takeaway. This could be a technique, a gotcha, a pattern, or a decision rationale that would help future-you (or someone like you) working on a similar problem.

4. **Which issue should be queued as `next-up` for the next session?** — ask for an issue number (or 'skip'). If the user gives a number, invoke `/handoff <N> --completed`. The `/handoff` skill is the canonical writer — it manages the GitHub `next-up` label and refreshes the local cache; the `--completed` flag keeps it in completion mode (label only — no note draft, no unchecked-box enforcement). This skill does not call `gh` directly for next-up label or cache writes (Step 1 still uses `gh pr list` for read-only context). If the user skips, move on silently.

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

- **This is not a gate.** It's a prompt. If the user doesn't want to reflect, respect that immediately.
- **Keep it lightweight.** Four questions max. No forms, no required fields, no ceremony.
- **The habit matters more than the log.** Even if nothing gets written down, the pause to think has value.
- **SRP:** This skill handles reflection only. `/cleanup` handles housekeeping. `/handoff` manages the GitHub `next-up` label. They are separate responsibilities, and the fourth interview question delegates to `/handoff` rather than duplicating the GH-write logic.

$ARGUMENTS
