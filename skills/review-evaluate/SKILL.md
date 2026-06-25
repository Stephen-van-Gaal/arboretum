---
name: review-evaluate
owner: git-workflow-tooling
scope: plugin-only
description: Evaluate collected PR review records from collect-review.sh and write a validated dispositions.json ledger for /land. Read-only with respect to GitHub; invoked by /land after collection.
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Skill
argument-hint: "<pr-number>"
layer: 0
---

# review-evaluate

Evaluate the collected review ledger for a PR and produce the disposition ledger
that `/land` and `/review-closeout` consume.

## When to use

- Invoked by `/land` after `bash scripts/collect-review.sh <pr>` has written
  `.arboretum/land/<pr>/comments.json`.
- Direct invocation when a human wants review feedback classified before
  deciding what to fix.

## Procedure

### Step 1: Apply receive-review discipline

Before classifying review records, invoke the review-reception wrapper:

```text
Skill arboretum:receive-review
```

Use it for the evaluation mindset: verify the feedback, separate correctness
from preference, and do not agree performatively with a reviewer.

### Step 2: Read collected facts

Read `.arboretum/land/<pr>/comments.json`. Treat it as the only source of
collected review facts. Do not read raw provider APIs to invent missing comment
ids.

Consider open inline records, unresolved backend threads, review summaries, and
substantive conversation comments. Ignore purely informational records only when
the reason is explicit in the disposition.

### Step 3: Classify every actionable item

Write `.arboretum/land/<pr>/dispositions.json` using
`docs/contracts/review-dispositions.contract.md`.

For each item, choose:

- `disposition`: `fix`, `already-addressed`, `defer`, `wont-fix`,
  `judgment-call`, `duplicate`, `outdated`, or `informational`
- `severity`: `substantive`, `nit`, or `none`
- `action`: `fix-in-batch`, `no-code-change`, `ask-human`, or
  `manual-follow-up`
- `cluster`: required for `fix`; use stable names such as `validation-gate` or
  `docs-closeout`
- `resolve_after_closeout`: true only when `/review-closeout` should reply and
  resolve the provider thread after evidence is pushed
- `reply`: the thread-level disposition text to post later, when applicable
- `reason`: the concise technical reason for the decision

Group clear-cut fixes by `cluster` so `/land` can fix all items in the cluster
together.

### Step 4: Validate the ledger

Run:

```bash
bash scripts/validate-review-dispositions.sh <pr>
```

Fix the ledger until validation passes. Surface any `ask-human` or
`manual-follow-up` items to the user before `/land` starts the fix loop.

## Write boundary

This skill is read-only with respect to providers and git history. It may write
only `.arboretum/land/<pr>/dispositions.json`.

Safety rules for this skill:

- do not post comments;
- do not resolve threads;
- do not push commits;
- do not request review;
- do not mutate GitHub/Azure DevOps state.

`/land` and `/review-closeout` own those later steps.
