---
name: land
owner: git-workflow-tooling
description: Drive an open pull request to merge-ready — poll CI and AI reviewers, triage and action feedback per thread, loop until CI is green with no substantive comments, then hand off by change tier. Chained from /finish; also runnable standalone on any open PR.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob, ScheduleWakeup, Skill
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

### Loop handler contract

Every entry into `/land` — cold (`/land <N>` or `/finish` → `/land`) or warm (`ScheduleWakeup` firing a `/loop /land <N>`) — runs three phases in strict order:

1. **Phase 1: Terminal check** — MERGED, CLOSED, branch deleted on remote, or PR not found. Exits without scheduling a wake-up.
2. **Phase 2: Stall check** — PR converted to draft, head SHA unchanged for ≥ 2 iterations, or CI in `action_required`. Surfaces guidance and exits without scheduling a wake-up.
3. **Phase 3: Active iteration** — existing poll → triage → fix → respond → resolve sequence. **This is the only callsite in the entire skill for `ScheduleWakeup`.**

`ScheduleWakeup` is fire-and-forget — once queued, the runtime delivers it regardless of intervening PR state changes. The termination guarantee therefore lives in the handler: Phases 1 and 2 never queue a wake-up, so a wake-up that fires after the PR has merged enters Phase 1, self-extinguishes, and queues nothing further.

### Stage logging

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /land entered
fi
```

At exit (when the procedure completes), log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /land exited
fi
```

### Phase 1: Terminal check

If `$ARGUMENTS` gives a number, use it. Otherwise resolve from the current branch:

```bash
if [ -n "${ARGUMENTS:-}" ]; then
  PR="$ARGUMENTS"
else
  PR=$(gh pr view --json number --jq .number 2>/dev/null) || PR=""
fi
```

If no PR exists, stop and tell the user.

Run the terminal check:

```bash
bash scripts/land-handler.sh check-terminal "$PR"
```

The helper emits `terminal=true|false` and (when terminal) `reason=merged|closed|branch-deleted|not-found` and `entry=cold|warm`.

- **`terminal=true` AND `entry=cold`** — surface to user (e.g. *"PR #N is already merged. Nothing to do."*), log `summary, phase: 1, terminal: true, reason: <reason>` via `log-stage.sh`, exit. Do **not** call `ScheduleWakeup`.
- **`terminal=true` AND `entry=warm`** — silent exit (the user did not ask; surfacing would be noise), log the same `summary` entry, exit. Do **not** call `ScheduleWakeup`.
- **`terminal=false`** — proceed to Phase 2.
- **`terminal=unknown` with `reason=fetch-failed`** — surface *"Couldn't read PR state for #N after retry — stopping. Re-invoke /land when GitHub is reachable."*, exit. Do **not** call `ScheduleWakeup`. (Termination wins over availability — see design spec § Error handling.)

### Phase 2: Stall check

Run the stall check:

```bash
bash scripts/land-handler.sh check-stall "$PR"
```

The helper emits `stall=true|false` and (when stalled) `reason=draft|head-sha-unchanged|ci-action-required` plus extra context fields.

- **`stall=true reason=draft`** — surface *"PR was converted to draft. Copilot does not review drafts. Flip to ready-for-review (`gh pr ready <N>`) and re-invoke /land."*, log `summary, phase: 2, stall: true, reason: draft` via `log-stage.sh`, exit. Do **not** call `ScheduleWakeup`.
- **`stall=true reason=head-sha-unchanged`** — surface *"No progress detected: head SHA unchanged across 2 iterations. Stopping to avoid runaway polling."*, log `summary, phase: 2, stall: true, reason: head-sha-unchanged, head_sha_unchanged_count: <N>`, exit. Do **not** call `ScheduleWakeup`.
- **`stall=true reason=ci-action-required`** — surface *"CI needs human approval to re-run. /land will stop here."*, log `summary, phase: 2, stall: true, reason: ci-action-required`, exit. Do **not** call `ScheduleWakeup`.
- **`stall=false`** — proceed to Phase 3.
- **`stall=unknown reason=fetch-failed`** — surface *"Couldn't read PR state for #N during stall check — stopping. Re-invoke /land when GitHub is reachable."*, exit. Do **not** call `ScheduleWakeup`.
- **`stall=unknown reason=ci-fetch-failed`** — surface *"Couldn't read CI status for #N during stall check — stopping. Re-invoke /land when the checks API is reachable."*, exit. Do **not** call `ScheduleWakeup`. (Termination wins over availability — design spec § Error handling forbids re-queueing against unknown state.)

### Phase 3: Active iteration

Poll two sources, then schedule a wake-up rather than blocking:

1. CI checks — `gh pr checks <N>`.
2. AI-reviewer feedback — line comments (`gh api repos/{owner}/{repo}/pulls/{N}/comments`) and review summaries (`gh api repos/{owner}/{repo}/pulls/{N}/reviews`), filtered to reviewers the repo has enabled (Copilot today; reviewer set is a Level-1 config fact — see the design spec).

(Terminal PR state is checked in Phase 1, not here.)

**Self-pacing requires `/loop` mode.** `ScheduleWakeup` is the polling mechanism — but it only fires inside a `/loop` parent. Invoked standalone (`/land <N>`), `ScheduleWakeup` queues a wake-up the runtime cannot act on, so the loop never advances beyond the first pass. Behave accordingly:

- **If invoked as `/loop /land <N>`**: perform one full iteration (poll → triage → fix-if-needed → respond → resolve threads → write head-SHA summary), then call `ScheduleWakeup` at ~900s with the same `/loop /land <N>` prompt.

  ```bash
  # ScheduleWakeup callsite — see "Loop handler contract" above.
  # This is the only place in the skill where this tool may be invoked.
  ```

- **If invoked standalone (`/land <N>` with no `/loop` parent)**: do not call `ScheduleWakeup` — it would silently no-op. Perform one full iteration, then surface the remaining state to the human with three options:
  (a) re-invoke `/land <N>` manually after re-reviews land,
  (b) wrap in `/loop` for autonomous polling (`/loop /land <N>`),
  (c) stop here and merge manually when ready.

Detecting `/loop` context from inside the skill is not currently possible — inferring intent from the user-facing invocation form is the only signal. When `/finish` chains into `/land` automatically, treat that chain as standalone unless `/finish` itself was invoked under `/loop`.

**At the end of every Phase 3 completion, before scheduling the wake-up (if any)**, write the head-SHA tracking entry. The journey log is keyed per `$ISSUE`; when `/land` runs standalone there may be no `$ISSUE` env, so fall back to the PR number so reads and writes stay aligned with `land-handler.sh`'s default:

```bash
# Compute next_head_sha_unchanged_count from check-stall's last output
# (passed forward via env or recomputed).
LAND_ISSUE="${ISSUE:-$PR}"
bash scripts/log-stage.sh "$LAND_ISSUE" /land summary \
  "phase=3" \
  "head_sha=$current_head_sha" \
  "head_sha_unchanged_count=$next_head_sha_unchanged_count"
```

### 3. Triage

Before classifying, invoke `Skill arboretum:receive-review` so per-comment evaluation discipline (verify before implement, no performative agreement) governs the triage decisions.

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

To resolve addressed threads after the fix push, invoke `Skill arboretum:receive-review`. That skill owns the GraphQL recipe (REST → thread node ID mapping + `resolveReviewThread` mutation) as the single source of truth — `/land` does not carry its own copy.

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
- The two caps (2 fix rounds in Phase 3 Step 4, head-SHA-unchanged ≥ 2 in Phase 2) guarantee termination. No wake-up is queued from Phase 1 or Phase 2.
- Graceful degradation: no `gh` -> stop with install guidance; no CI configured
  -> skip the CI signal, still poll reviewers.
