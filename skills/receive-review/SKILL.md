---
name: receive-review
owner: receive-review
description: Apply receive-review discipline — verify-before-implement and no-performative-agreement (via superpowers:receiving-code-review) plus arboretum extras (GraphQL thread-resolve after fix push, paired-stub-sync check when feedback touches a design spec). Invoked by /land Steps 3 + 5; also invocable directly for ad-hoc feedback contexts (Slack critique, in-session pushback, manual gh comment responses outside /land).
disable-model-invocation: false
allowed-tools: Bash, Read, Skill
---

# receive-review

Apply arboretum's receive-review discipline at any moment review feedback is being processed.

## When to use

- Auto-invoked by `/land` Step 3 (triage) and Step 5 (per-thread responses).
- Direct invocation for ad-hoc feedback contexts: Slack critique on a PR or design, in-session pushback during pairing, manual `gh` comment responses outside `/land`.

## Procedure

This skill runs a three-step contract, in order, every invocation.

### Step 1: Delegate to superpowers:receiving-code-review

Invoke the upstream skill to govern per-comment evaluation discipline (verify before implement, no performative agreement, push back with technical reasoning when feedback is wrong for this codebase, ask before assuming, no gratitude expressions in replies).

```
Skill superpowers:receiving-code-review
```

The wrapper does not duplicate or rewrite that content — upstream is the single source of truth for the mindset.

### Step 2: After any fix push in a PR context, resolve addressed threads via GraphQL

**This step is conditional on a PR review context** — a GitHub PR with review threads attached and a fix push just landed. In non-PR contexts (Slack critique, in-session pushback, manual responses on artifacts that aren't GitHub PRs) this step is a no-op; skip and proceed to Step 3.

REST's `gh api repos/{owner}/{repo}/pulls/{N}/comments` returns comment `databaseId`s, not the thread node IDs that `resolveReviewThread` requires. First, map REST comment IDs to GraphQL thread node IDs. The recipe below uses GraphQL variables so it is **executable as written** (bare identifiers like `repository(owner: OWNER, …)` are not valid GraphQL — `owner`/`name` are string-typed arguments, so they must be passed as variables or string literals):

```bash
gh api graphql \
  -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" \
  -f query='query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes { id comments(first: 1) { nodes { databaseId } } }
        }
      }
    }
  }'
```

Then for each addressed thread, resolve it:

```bash
gh api graphql \
  -f threadId="$THREAD_ID" \
  -f query='mutation($threadId:ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }'
```

Leave a thread open deliberately when its item is genuinely outstanding. Replies on a thread should explain disposition — they are a learning record, not a bare acknowledgement.

### Step 3: If feedback touches a design spec, surface paired-stub-sync check

When the feedback being processed targets a design spec (path matches `docs/superpowers/specs/*-design.md`), surface this check before the fix push:

> Paired-stub-sync check — derivative surfaces to update in the same commit:
> - Shared-concept stubs (`docs/superpowers/specs/*-shared-concepts.md`)
> - Decision-summary rows in related design specs
> - Cross-WS impact tables in mega-epic design specs
> - Frontmatter (status, related-issue, depends-on, consumes, produces)

This is a surfaced reminder, not a blocking gate. If the design-spec fix is genuinely self-contained, acknowledge and proceed. The point is to make the drift class visible — PR #309 had 3 of 7 review rounds catch exactly this drift class.

## Non-goals

- Not a workflow loop. `/land`'s poll → triage → fix → respond loop stays in `/land`.
- Not a replacement for `superpowers:receiving-code-review` — delegates to it.
- Not a pre-fix planner — runs at receive-and-respond time.
