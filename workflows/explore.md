---
name: explore
requires:
  - superpowers
---

# Workflow: Explore

You don't know enough to write a spec yet. Spike, learn, and either produce a spec draft or a documented decision about what not to build.

## When to use

- You have a question about feasibility ("can we do X?")
- You need to evaluate a library, API, or approach
- You're not sure how to decompose a problem into specs
- You want to prototype before committing to a design

## Spike vs. build — what are you producing?

The explore workflow accommodates both *spikes* (output is knowledge) and the early stages of a build that will eventually ship. The decision rule is **"what artifact emerges at the end?"**

- **Spike:** the deliverable is a *findings document*. Code (if any) is reference-only and never owned by a spec. Branch is `spike/*` and gets deleted after the findings are captured.
- **Pre-build exploration:** the deliverable will eventually become *shipped code* with an owning governed spec. Branch is `feat/*` and merges via the build workflow.

If you don't know yet, start as a spike — it's easier to graduate to a build later than to retroactively delete code that turned out to be exploratory.

## Stages

```
/start → [spike → document]* → decide
```

## Artifact Flow

| Step | Reads | Produces | Location | Authority |
|---|---|---|---|---|
| 1. `/start` | the question, codebase | issue framed as a question (not a deliverable) | GitHub issue | — |
| 2a. Spike | code, docs, library / API surface | throwaway working code | `spikes/` or `spike/*` branch | (throwaway — never owned) |
| 2b. Document | spike outcome | findings (what tried / what worked / what now known / next question) | issue body or markdown file | ephemeral |
| 3. Decide | findings | exit choice (continue / build / file / close) | issue + branch state | — |

### 1. Start — `/start`

Create a GitHub issue framed as a question, not a deliverable. "Can we use X for Y?" or "What's the right way to handle Z?"

**Output:** An issue that captures what you're trying to learn.

### 2. Spike-document cycle — repeat as needed

#### 2a. Spike

Write throwaway code to answer a specific question. Spikes live in `spikes/` or a feature branch.

**Ground rules:**
- Spikes are throwaway. Don't polish them.
- Each spike should target one question. "Does this API return what we need?" not "Build the whole feature."
- Time-box if possible. If you haven't learned what you need in a reasonable effort, the question may be wrong.

**Skills:** `superpowers:systematic-debugging` (if investigating existing systems), or hands-on experimentation.

#### 2b. Document

Write down what you learned. This doesn't need to be formal — a few sentences in the issue or a markdown file is fine. The point is to capture the knowledge before you forget it.

**Key questions to answer:**
- What did you try?
- What worked? What didn't?
- What do you now know that you didn't before?
- What's the next question?

### 3. Decide

Document your findings, then choose one of four options:

1. **Continue exploring** — more knowledge needed. Keep spiking on the same branch or start a new spike.
2. **Transition to the build workflow** — enough knowledge to start code. Document, then start a `feat/*` branch via `/start` → `/design`. `/design`'s Branch 1 dispatch picks the appropriate mode (brainstorm / investigate / coverage-baseline / none) based on what the spike taught you.
3. **File for later** — worth doing, but not now. Capture findings as a tracked GitHub issue, close the spike branch.
4. **Close (no action)** — the spike answered "no, not worth doing" or "no change needed." Close the branch with the findings retained as a record.

Re-invoke `/start` with the chosen next step. The findings document remains as historical record regardless of the choice.

## Exit criteria

One of:
- A design spec at `docs/superpowers/specs/` ready to enter the build workflow at `/design`
- A documented decision not to proceed (in the GitHub issue)
- A clear next question for another spike cycle

## Transitions

- **→ build:** When a spike produces enough understanding, `/consolidate` findings into a design spec and enter the build workflow at `/design`.
- **← build:** If during `/design` you discover the question is too open to specify, enter this workflow to spike. Return to `build` via `/consolidate`.
