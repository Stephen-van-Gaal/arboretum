---
name: land
description: Drive an open pull request to merge-ready — poll CI and AI reviewers, triage and action feedback per thread, loop until CI is green with no substantive comments, then hand off by change tier. Chained from /finish; also runnable standalone on any open PR.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob, ScheduleWakeup
argument-hint: "[<pr-number>]"
layer: 0
---

# Land

Drive an open pull request from "just opened" to "merge-ready" — without the
human prompting each step.

## When to use

- Chained automatically by `/finish` after a PR is created.
- Standalone on any open PR: `/land <pr-number>`.

## Procedure

### 1. Resolve the PR

If `$ARGUMENTS` gives a number, use it. Otherwise resolve from the current
branch: `gh pr view --json number,state,headRefName`. If no PR exists, stop and
tell the user. If the PR is already `MERGED` or `CLOSED`, stop.

### 2. Poll loop

Poll three sources, then schedule a wake-up rather than blocking:

1. CI checks — `gh pr checks <N>`.
2. AI-reviewer feedback — line comments (`gh api repos/{owner}/{repo}/pulls/{N}/comments`)
   and review summaries (`gh api repos/{owner}/{repo}/pulls/{N}/reviews`), filtered
   to reviewers the repo has enabled (Copilot today; reviewer set is a Level-1
   config fact — see the design spec).
3. PR state — a `MERGED`/`CLOSED` PR short-circuits the loop.

Use `ScheduleWakeup` at ~900s. Cap at 3 consecutive empty polls (~45 min), then
surface the absence and stop.

### 3. Triage

Classify each substantive comment:

- **Clear-cut** — real bug, encoding error, unhandled input, dead code, security
  issue. -> auto-fixable.
- **Judgment-call** — design choice, debatable trade-off, "would be nice."
  -> surfaced to the human, not auto-fixed.

Before acting, present the triage results:

> "Triage complete. Planning to fix: [list clear-cut items]. Judgment-calls to surface: [list]. Say 'stop' to interrupt, otherwise proceeding in 10 seconds."

Wait briefly for interruption, then proceed. This is a notification, not a gate — it preserves autonomous operation while giving the human visibility into what is about to change.

### 4. Fix sub-loop (cap: 2 rounds)

Fix all clear-cut comments **together in one commit**, push, and re-request
review. CI failures are fixed the same way. Re-enter the poll loop. After **2**
fix rounds, stop fixing — surface whatever remains as judgment-calls.

### 5. Per-thread responses

For **every** review comment, reply on its own thread:

- **Fixed** — disposition + the commit SHA that addressed it.
- **Deferred / won't-fix** — the reason.
- **Judgment-call** — the reasoning and recommendation.

Reply via `gh api repos/{owner}/{repo}/pulls/{N}/comments -f body=... -F in_reply_to=<comment-id>`.

To resolve addressed threads, first fetch thread node IDs — the REST API returns
comment/review IDs, not the GraphQL thread IDs that `resolveReviewThread` requires:

```bash
gh api graphql -f query='
{
  repository(owner: OWNER, name: REPO) {
    pullRequest(number: N) {
      reviewThreads(first: 100) {
        nodes { id comments(first: 1) { nodes { databaseId } } }
      }
    }
  }
}'
```

Map each REST comment `databaseId` to its thread `id`, then resolve:

```bash
gh api graphql -f query="mutation {
  resolveReviewThread(input: {threadId: \"<thread-node-id>\"}) {
    thread { isResolved }
  }
}"
```

Leave a thread open deliberately when its item is genuinely outstanding. Write
replies to *explain* — they are a learning record, not bare acknowledgements.

### 6. Exit condition

Exit the loop when CI is green **and** no substantive comments remain.

### 7. Tiered merge handoff

Classify the change using the PR's actual diff (correct in both chained and standalone mode):
`gh pr diff <N> --name-only | bash scripts/classify-pr-change.sh --files-from -`

- **`docs-config`** -> enable GitHub auto-merge: `gh pr merge <N> --auto --squash`.
  GitHub merges once branch protection is satisfied. The agent never merges.
- **`code`** -> do not enable auto-merge. Notify the human: the PR is
  merge-ready and awaits their merge.

## Important

- `/land` never merges directly — `docs-config` delegates to GitHub auto-merge;
  `code` hands off to the human.
- The cap (2 fix rounds, 3 empty polls) guarantees termination.
- Graceful degradation: no `gh` -> stop with install guidance; no CI configured
  -> skip the CI signal, still poll reviewers.
