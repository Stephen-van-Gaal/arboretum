---
name: review-closeout
owner: git-workflow-tooling
scope: plugin-only
description: Close the PR review loop after fixes are pushed by validating review ledgers, posting per-thread dispositions, resolving addressed GitHub review threads, posting a top-level summary, and writing closeout evidence.
disable-model-invocation: false
allowed-tools: Bash, Read, Skill
argument-hint: "<pr-number>"
layer: 0
---

# review-closeout

Close the provider-visible review loop after `/land` has fixed clear-cut review
items, committed the fix, pushed it, and verified current head/readiness safety.

## When to use

- Invoked by `/land` after the fix push and after the current PR head has been
  verified safe for closeout.
- Direct invocation only for inspection or dry-run planning unless the caller
  has already performed the same `/land` safety checks.

## Procedure

### Step 1: Apply receive-review discipline

Invoke the review-reception wrapper so thread replies follow the established
review-response discipline:

```text
Skill arboretum:receive-review
```

### Step 2: Validate review decisions

Run:

```bash
bash scripts/validate-review-dispositions.sh <pr>
```

Stop if validation fails. Closeout must not repair or reinterpret an invalid
`dispositions.json` ledger.

### Step 3: Dry-run the provider writes

Run:

```bash
bash scripts/post-review-closeout.sh <pr> --dry-run
```

Surface the planned per-thread replies, thread resolutions, top-level summary,
and remaining-open count. If this fails, stop before any live provider writes.

### Step 4: Run live closeout only after `/land` safety checks

When invoked by `/land` after fixes are pushed and head/readiness checks have
passed, run:

```bash
bash scripts/post-review-closeout.sh <pr>
```

The helper owns the write order: per-thread replies, GraphQL thread resolution,
top-level summary comment, then `.arboretum/land/<pr>/closeout.json`.

### Step 5: Report remaining open items

Read `.arboretum/land/<pr>/closeout.json` and report the `remaining_open` list.
`/land` must not claim merge-ready while this list contains substantive
undisposed items.

## Safety boundary

This skill does not classify feedback or edit code. It consumes already
validated ledgers and delegates provider mutation to
`scripts/post-review-closeout.sh`.
