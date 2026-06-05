---
name: design-package
owner: workflow-unification
description: Build the human review packet for a design session: recognize the AI-facing session artifact, generate the overview, prepare the Durable Document Change Set, and drive durable-doc diff review before /design exits.
disable-model-invocation: false
allowed-tools: Bash, Read, Grep
argument-hint: "<path/to/session-design.md>"
layer: 0
---

# Design Package

Builds the human review packet for a design session.

`design-package` is the second Slipstream skill in the design activity. It is
invoked by `design` after the AI-facing session document exists, planning has
been folded in, and the `plan:` field is final. It runs before `/design` exits
to `/build`. It is not a standalone workflow stage and does not own `/design`;
`design` remains the conductor.

## When To Use

Use from `design` after Branch 1 has produced an AI-facing session/design
artifact and plan fold-in has produced or intentionally omitted the plan. The
session artifact's S2 `plan:` field must point at the final path or be `null`
before this skill claims `/build` buildability. Standard invocation:

```text
design-package <path/to/session-design.md>
```

## Procedure

### 1. Validate buildability when applicable

If the artifact is intended to be passed to `/build`, run the S2 validator:

```bash
bash scripts/validate-design-spec.sh <path>
```

If validation fails, do not claim the artifact is buildable. Surface the
validator output and return to `design`.

Do not run this buildability check against a pre-plan draft that still has a
future `plan:` path in frontmatter. `design` must fold in the plan first, or set
`plan: null` for truly planless direct work, so the S2 check validates the same
artifact `/build` will consume.

### 2. Discover the document shape

Run:

```bash
bash scripts/explore-doc.sh <path>
```

Use both cataloged shape keys and discovered heading keys returned by
`explore-doc.sh`. Cataloged keys give stable defaults; discovered heading keys
let the package include useful session sections that are not yet in
`docs/templates/document-shapes.yaml`.

### 3. Classify the source

Classify the artifact before summarizing:

| Classification | Recognition rule | Handling |
|---|---|---|
| `strict-design-session` | S2 frontmatter plus most canonical design-spec headings such as `Context`, `Problem`, `Intended Behaviour`, `Existing Authority`, `Proposed Document Changes`, `Implementation Shape`, `Test Strategy`, and `Build Handoff`. | Retrieve canonical sections and any relevant discovered headings. |
| `partial-design-session` | S2 frontmatter plus at least four overview-bearing headings such as `Problem`, `Intended Behaviour`, `Customer Experience`, `Implementation Shape`, or `Build Handoff`. | Retrieve available sections and mark missing optional parts. |
| `custom-s2-design-session` | S2 frontmatter plus equivalent headings such as `Purpose`, `Requirements`, `Architecture`, `Milestones`, `Test Approach`, `Customer Experience`, or `Boundaries`. | Map equivalent headings into the overview standard with lower confidence. |
| `plan` | Plan-shaped headings such as `File Structure`, `Task N`, and `Final Verification`. | Summarize as AI execution context only; do not claim durable intent authority. |
| `unknown` | No S2 frontmatter and no recognized plan/session shape. | Refuse to summarize. |

The package must fail closed on `unknown`. Show the missing recognition signals instead of
producing a confident summary from arbitrary Markdown.

### 4. Retrieve sections

Retrieve only the sections needed for the package:

```bash
bash scripts/read-doc-sections.sh <path> <key> [<key>...]
```

Prefer keys discovered in Step 2. If semantic retrieval fails for an optional
section, continue with an explicit missing-section note. If required context is
unavailable, stop and return to `design`.

### 5. Emit the session overview

Use exactly this overview standard:

```markdown
## Session Overview

**Why this session exists:**

**What will change:**

**Durable Document Change Set:**
| File | Operation | High-Level Change | Why It Matters | Phase |
|---|---|---|---|---|

**Human decisions or review points:**

**What the AI will do:**

**Tests and confidence:**

**Stop conditions:**
```

Keep this overview compact. It is for the human to understand the session and
the durable authority being changed, not for the AI to execute every task.

### 6. Prepare durable-document review

The Durable Document Change Set lists exact files, operation type, high-level
change, why it matters, and phase. Use these boundaries:

| Durable document class | Pre-build action |
|---|---|
| Intent authority | May be edited before build. Includes purpose, problem, scope, requirements, customer/operator experience, architecture boundaries, naming, splitting/lumping, trade-offs, and Behaviour/Boundaries-style human prose. |
| Seam authority | May be edited before build when implementation depends on it. Includes definitions and contracts the implementation must obey. |
| Generated/evidence authority | Do not finalize before build unless the evidence already exists. Ownership, Tests, Design record, decision harvest, register, and contract coverage remain `/finish`/`/consolidate` work. |

The package must preserve intent authority, seam authority, and
generated/evidence boundaries.

Present the overview and durable-doc diff to the human. Do not let provider
detail masquerade as human authority. Do not commit or push durable edits
without explicit human approval.

### 7. Return package status to `design`

Return one of:

- `approved` — the human approved the overview and durable-doc diff.
- `revision-requested` — update the session artifact or durable edits, then run
  this skill again.
- `stop` — the artifact is `unknown`, S2 buildability failed, generated/evidence
  authority would need to be faked, or implementation would require a new design
  decision.

`design` remains responsible for logging `/design exited`, committing and
pushing approved durable edits unless a future implementation explicitly moves
that guarded command sequence into this skill, and handing off to `/build`.
