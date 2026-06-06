---
name: land
owner: git-workflow-tooling
description: Drive an open pull request to merge-ready through the configured repo backend. GitHub gets the full CI/reviewer loop; Azure DevOps gets explicit PR state/policy checks and merge handoff guidance. Chained from /finish; also runnable standalone on any open PR.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob, ScheduleWakeup, Skill
argument-hint: "[<pr-number>]"
layer: 0
---

# Land

Drive an open pull request from "just opened" to "merge-ready" through the
project's configured repo backend. GitHub keeps the autonomous poll/fix/respond
loop. Azure DevOps uses Azure Repos state and policy checks, then hands off
unsupported reviewer-thread automation explicitly instead of falling into `gh`.

## When to use

- Chained automatically by `/finish` after a PR is created.
- Standalone on any open PR: `/land <pr-number>`.

## Procedure

### Loop handler contract

On the `github` backend, every entry into `/land` — cold (`/land <N>` or
`/finish` → `/land`) or warm (`ScheduleWakeup` firing a `/loop /land <N>`) —
runs three phases in strict order:

1. **Phase 1: Terminal check** — MERGED, CLOSED, branch deleted on remote, or PR not found. Exits without scheduling a wake-up.
2. **Phase 2: Stall check** — PR converted to draft, head SHA unchanged for ≥ 2 iterations, or CI in `action_required`. Surfaces guidance and exits without scheduling a wake-up.
3. **Phase 3: Active iteration** — poll → collect → evaluate → fix/push → closeout → re-request/merge handoff sequence. **This is the only callsite in the entire skill for `ScheduleWakeup`.**

`ScheduleWakeup` is fire-and-forget — once queued, the runtime delivers it regardless of intervening PR state changes. The termination guarantee therefore lives in the handler: Phases 1 and 2 never queue a wake-up, so a wake-up that fires after the PR has merged enters Phase 1, self-extinguishes, and queues nothing further.

On `azure-devops`, `/land` does not use this handler. It follows the Azure
DevOps path below and exits after state/policy review plus merge handoff.

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

### Backend dispatch

Before resolving or polling any PR, read the configured backend:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
LAND_BACKEND="${SHIP_BACKEND:-$(roadmap_backend "$PROJECT_DIR")}"
export LAND_BACKEND
roadmap_probe_backend_access "$LAND_BACKEND" "$PROJECT_DIR" || exit 1
```

- **`github`** — run the three-phase handler below. This path owns all `gh`
  usage in `/land`.
- **`azure-devops`** — skip the GitHub handler and run Section "Azure DevOps
  path" below. Do not call `gh pr view`, `gh pr checks`, `gh api`, or
  `scripts/land-handler.sh`.
- **Any other backend** — stop with: *"Unsupported PR backend: <backend>.
  Supported backends: github, azure-devops."*

### Phase 1: Terminal check

GitHub path only.

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

### Phase 1.5: Remote readiness gate

GitHub path only.

Before the stall check, review collection, thread resolution, or local full CI,
run the remote readiness gate:

```bash
REMOTE_READINESS="$(bash scripts/pr-readiness.sh remote "$PR" --allow-draft)"
printf '%s\n' "$REMOTE_READINESS"
```

Handle the normalized result:

- **`readiness=draft-clean`** — mark the PR ready (`gh pr ready "$PR"`),
  request configured reviewers (`bash scripts/request-review.sh "$PR"`), then
  re-run remote readiness without `--allow-draft` and wait for GitHub to
  recompute.
- **`readiness=ready`** — proceed to Phase 2 and active review/CI work.
- **`reason=ci-failing`** — foreground failing checks as the first triage item;
  route into the fix loop before reviewer triage.
- **`readiness=waiting`** — surface pending CI and wait or schedule per the
  existing loop mode.
- **`readiness=blocked`** — stop before `collect-review.sh`, review-thread
  resolution, or local full CI.
- **`readiness=unknown`** — stop after bounded polling with retry guidance.

After any fix or rebase push, re-run `scripts/pr-readiness.sh remote "$PR"` and
wait for mergeability recomputation before resolving addressed review threads.

### Phase 2: Stall check

GitHub path only.

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

GitHub path only.

Poll two sources, then schedule a wake-up rather than blocking:

1. CI checks — `gh pr checks <N>`.
2. Reviewer feedback — run `bash scripts/collect-review.sh <N>`. It aggregates **every** comment surface (review summaries, inline threads, conversation comments; ADO PR threads on the `azure-devops` backend) into one backend-neutral normalized record written to the ledger `.arboretum/land/<N>/comments.json`, with a separate `approvals.json` channel. Read triage input from that **ledger file**, not from raw `gh api` calls or the captured stdout — the script is the single place that knows which surfaces to query and how to normalize them into one backend-neutral record set. (It collects every author's comments; it does not filter to the `.arboretum.yml` reviewer list — that config drives *requesting* review, in `request-review.sh`.)
3. Review evaluation — invoke `Skill arboretum:review-evaluate <N>`. It applies receive-review discipline and writes `.arboretum/land/<N>/dispositions.json`; `/land` reads fix clusters and judgment calls from that validated ledger.

(Terminal PR state is checked in Phase 1, not here.)

**Self-pacing requires `/loop` mode.** `ScheduleWakeup` is the polling mechanism — but it only fires inside a `/loop` parent. Invoked standalone (`/land <N>`), `ScheduleWakeup` queues a wake-up the runtime cannot act on, so the loop never advances beyond the first pass. Behave accordingly:

- **If invoked as `/loop /land <N>`**: perform one full iteration (poll → collect → evaluate → fix-if-needed → push → closeout → write head-SHA summary), then call `ScheduleWakeup` at ~900s with the same `/loop /land <N>` prompt.

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

### 3. Evaluate review records

Invoke:

```text
Skill arboretum:review-evaluate <N>
```

Before classifying, invoke `Skill arboretum:receive-review`. In normal `/land`
execution, this happens through `review-evaluate`; keep that review-reception
discipline before disposition writing.

That skill invokes `Skill arboretum:receive-review`, classifies each collected
record, and writes the validated disposition ledger:
`.arboretum/land/<N>/dispositions.json`.

Read fix clusters and human judgment calls from that ledger:

- **Clear-cut fix clusters** — disposition `fix` with action `fix-in-batch`.
- **Already-addressed / no-code-change items** — reply later during closeout.
- **Judgment-call / ask-human items** — surface to the human, not auto-fixed.
- **Deferred / won't-fix / manual-follow-up items** — keep open unless the
  disposition explicitly says closeout should reply and resolve.

Before acting, present the triage results:

> "Triage complete. Planning to fix: [list clear-cut items]. Judgment-calls to surface: [list]. Say 'stop' to interrupt, otherwise proceeding in 10 seconds."

Wait briefly for interruption, then proceed. This is a notification, not a gate — it preserves autonomous operation while giving the human visibility into what is about to change.

### 4. Fix sub-loop (cap: 2 rounds)

Fix all clear-cut clusters **together in one commit**, push, and write
`.arboretum/land/<N>/fixes.json` with real pushed commit SHAs keyed by
`comment_id`. CI failures are fixed the same way. Once a PR is ready, commits
trigger hosted CI through the `pull_request` `synchronize` activity, so do not
create per-comment commits. Batch one review/CI round, push once, re-run remote
readiness, and re-request review only when the new head is appropriate for
reviewers.

Before provider-visible closeout, run the current head/readiness safety check:

- the local worktree HEAD matches the PR head;
- every cited fix SHA is reachable from the PR head;
- readiness/mergeability is not dirty or unknown.

Stop before GitHub mutation if any check fails.

After **2** fix rounds, stop fixing — surface whatever remains as
judgment-calls.

### 5. Review closeout

Do not resolve addressed threads until the pushed fix has been followed by a
successful remote readiness recompute for the new head.

Leave a thread open deliberately when its item is genuinely outstanding. Write
replies to *explain* — they are a learning record, not bare acknowledgements.

Invoke:

```text
Skill arboretum:review-closeout <N>
```

That skill validates `dispositions.json`, dry-runs
`scripts/post-review-closeout.sh <N> --dry-run`, then runs the live helper only
after the fix push and head/readiness safety checks. The helper writes in this
order:

1. per-thread replies;
2. addressed GitHub thread resolution;
3. top-level review summary comment;
4. `.arboretum/land/<N>/closeout.json`.

Then run `bash scripts/request-review.sh <N> --re-request` when the configured
review policy says another review round is needed. Re-enter the poll loop.

### 6. Exit condition

Exit the loop only when CI is green, `bash scripts/collect-review.sh <N>
--unanswered` returns no substantive undisposed records, and
`.arboretum/land/<N>/closeout.json` has no substantive `remaining_open` items.
Do not declare merge-ready while either hanging-review surface still contains
substantive feedback.

At the final merge-ready or deliberate pause point, report ship-tail metrics
when the data is available:

```text
initial_remote_readiness=<value> initial_remote_reason=<value> ci_turns=<count|unknown> post_ready_pushes=<count|unknown> mergeability_blocks=<count> readiness_unknown_polls=<count> final_remote_readiness=<value>
```

If `$ISSUE` is available, write the same metrics through the existing tracker
journey log, not a local `.arboretum` log file:

```bash
bash scripts/log-stage.sh "$ISSUE" /land summary \
  initial_remote_readiness=<value> \
  initial_remote_reason=<value> \
  ci_turns=<count|unknown> \
  post_ready_pushes=<count|unknown> \
  mergeability_blocks=<count> \
  readiness_unknown_polls=<count> \
  final_remote_readiness=<value>
```

### 7. Tiered merge handoff

GitHub path only.

Classify the change using the PR's actual diff (correct in both chained and standalone mode):
`gh pr diff <N> --name-only | bash scripts/classify-pr-change.sh --files-from -`

- **`docs-config`** -> enable GitHub auto-merge: `gh pr merge <N> --auto --squash`.
  GitHub merges once branch protection is satisfied. The agent never merges.
- **`code`** -> do not enable auto-merge. Notify the human: the PR is
  merge-ready and awaits their merge.

## Azure DevOps path

This path exists so ADO-backed projects can ship without GitHub commands. It is
intentionally less autonomous than the GitHub path until Arboretum has an ADO
review-thread adapter.

### ADO 1. Resolve PR

If `$ARGUMENTS` gives a number, use it as the Azure Repos pull request ID.
Otherwise resolve the active PR for the current branch:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR=$(az repos pr list \
  --source-branch "$BRANCH" \
  --status active \
  --query '[0].pullRequestId' \
  -o tsv)
```

If no PR is found, stop and tell the user:
> "No active Azure Repos PR found for <branch>. Create one with `/pr`, or pass the PR id: `/land <id>`."

Fetch state:

```bash
PR_JSON=$(az repos pr show --id "$PR" --output json)
```

- `status` is `completed` -> surface "PR <id> is already completed. Nothing to do." and exit.
- `status` is `abandoned` -> surface "PR <id> is abandoned. Nothing to do." and exit.
- `isDraft` is true -> surface "PR <id> is still draft. Mark it ready in Azure Repos, then re-run `/land <id>`." and exit.

### ADO 2. Policy and reviewer signal

Read branch policy status:

```bash
POLICY_JSON="$(az repos pr policy list --id "$PR" --output json)"
```

If the command is unavailable or fails, degrade explicitly:
> "Couldn't read Azure Repos policy status for PR <id>. Review the PR in Azure DevOps and re-run `/land <id>` when policies are satisfied."

If any **blocking** policy is queued, running, rejected, or failed, summarize the
policy names and stop. Ignore optional (`isBlocking == false`) policy failures
for merge handoff because Azure Repos autocomplete waits on required policies by
default:

```bash
BLOCKING_POLICY_FAILURES="$(printf '%s\n' "$POLICY_JSON" | python3 -c '
import json, sys
bad = {"queued", "running", "rejected", "failed", "error", "broken"}
items = json.load(sys.stdin)
def truthy(value):
    return value is True or str(value).lower() == "true"
for item in items:
    cfg = item.get("configuration") or {}
    status = str(item.get("status") or item.get("Status") or "").lower()
    blocking = any(
        truthy(value)
        for value in (
            item.get("isBlocking"),
            item.get("blocking"),
            item.get("Blocking"),
            cfg.get("isBlocking"),
            cfg.get("blocking"),
        )
    )
    if blocking and status in bad:
        name = (
            item.get("displayName")
            or item.get("name")
            or ((cfg.get("type") or {}).get("displayName"))
            or cfg.get("displayName")
            or cfg.get("name")
            or "<unnamed policy>"
        )
        print(f"{name}: {status}")
')"
```

If `$BLOCKING_POLICY_FAILURES` is non-empty, summarize it and stop. Do not
schedule a wake-up unless the parent invocation is explicitly `/loop /land <id>`
and the user has asked for polling.

Reviewer-thread triage is not yet automated for Azure DevOps. Surface this
clearly:
> "Azure reviewer-thread automation is not implemented yet. Review any ADO comments in the PR UI; I can continue after you re-run `/land <id>`."

Stop here unless the user has explicitly confirmed in the current conversation
that all ADO reviewer comments have been reviewed/resolved and that `/land`
should continue to the merge handoff. Without that confirmation, do not run ADO
3 and do not queue autocomplete.

### ADO 3. Tiered merge handoff

Classify the Azure Repos PR's actual source/target diff, not the current local
checkout. Use the PR metadata fetched in ADO 1:

```bash
SOURCE_REF="$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sourceRefName",""))')"
TARGET_REF="$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("targetRefName",""))')"
SOURCE_BRANCH="${SOURCE_REF#refs/heads/}"
TARGET_BRANCH="${TARGET_REF#refs/heads/}"
REMOTE="${REMOTE:-origin}"
git fetch "$REMOTE" \
  "+refs/heads/$TARGET_BRANCH:refs/remotes/$REMOTE/$TARGET_BRANCH" \
  "+refs/heads/$SOURCE_BRANCH:refs/remotes/$REMOTE/$SOURCE_BRANCH"
git diff "$REMOTE/$TARGET_BRANCH...$REMOTE/$SOURCE_BRANCH" --name-only \
  | bash scripts/classify-pr-change.sh --files-from -
```

If PR refs are unavailable, a fetch fails, or the source repository is not the
current repo, stop and surface a portal handoff. Do not use `HEAD` as a fallback
for ADO classification.

- **`docs-config`** -> offer Azure Repos autocomplete rather than merging
  directly:

  ```bash
  az repos pr update --id "$PR" --auto-complete true --squash true --delete-source-branch true
  ```

  If the CLI rejects an autocomplete flag for the user's Azure DevOps extension
  version, surface the portal handoff instead of inventing a fallback merge.
- **`code`** -> do not autocomplete. Notify the human that the PR is
  merge-ready once ADO policies are satisfied and awaits their merge.

## Important

- `/land` never merges directly — `docs-config` delegates to GitHub auto-merge;
  on Azure DevOps, `docs-config` may delegate to Azure Repos autocomplete;
  `code` hands off to the human.
- The two caps (2 fix rounds in Phase 3 Step 4, head-SHA-unchanged ≥ 2 in Phase 2) guarantee termination. No wake-up is queued from Phase 1 or Phase 2.
- Graceful degradation: missing provider CLI/auth -> stop with the selected
  backend's prerequisite diagnostic; no CI configured on GitHub -> skip the CI
  signal, still poll reviewers; unavailable ADO policy status -> hand off to the
  user with the PR id and re-run instruction.
