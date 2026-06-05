---
name: finish
owner: git-workflow-tooling
description: Complete implementation work — verify, reconcile spec status to active via /consolidate if needed, and create a pull request. Use when implementation is done and you're ready to ship.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob
layer: 0
---

# Finish

Guides the transition from "code is done" to "PR is created." Orchestrates verification, spec promotion, and PR creation in the right order.

## When to use

- Implementation is complete
- User says "I think we're done", "create a PR", "let's wrap up"
- After the implement → commit loop is finished

## Procedure

### Step 0: Read the pipeline.workflow flag from the project root

Before any other step, resolve the active worktree root:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
```

Then validate the active named pipeline from that root:

```bash
PIPELINE="$(cd "$PROJECT_DIR" && bash "$PROJECT_DIR/scripts/read-pipeline-flag.sh")"
```

Also read the configured repo backend from the same root so the ship tail can use
the correct PR provider:

```bash
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
SHIP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export SHIP_BACKEND
```

The reader must succeed before the ship tail continues. The current
general-release pipeline follows the sequence below; `/security-review` is
mandatory and self-gates when no injection surface is present.

### Step 1: Verify implementation state

**Routing on `/build`'s exit-status (S3-8).** Before any other verification, read the most recent `/build exited` journey-log entry on the active issue and route on its `exit-status:` value. Until `scripts/get-latest-stage-log.sh` ships (WS9 follow-up), this is a descriptive routing — the operator confirms which path `/build` exited on:

When `exit-status: success` is the most recent `/build exited` value, continue the ship tail below (verify → consolidate → security-review → ship → PR).

When `exit-status: escape-hatch` is the most recent `/build exited` value, return to `/design` with the design spec as the in-flight authority. Halt — do not invoke `/pr` or any later stage. The escape-hatch outcome means the build surfaced a design decision that requires returning to `/design`.

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /finish entered
fi
```

Check the current state:

```bash
git status --short
git log $(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)..HEAD --oneline
```

Report:
- **Uncommitted changes:** If any, offer a `stage named files + commit checkpoint` before pausing.
- **Commits on branch:** List them so the user can confirm the work is complete
- **Current branch:** Confirm it's a feature branch

If there are uncommitted changes, the checkpoint is:

1. Show `git status --short`.
2. Ask which exact files to stage.
3. Run `git add -- <file> [<file>...]` with only those named files.
4. Ask for or confirm the commit message, referencing the active issue when available.
5. Run `git commit --only -m "<message>" -- <file> [<file>...]` so pre-existing staged entries are not swept into the checkpoint commit.
6. Re-run `git status --short`; continue only when clean.

If the operator declines the checkpoint, wait for them to resolve the dirty tree before proceeding.

### Step 2: Identify affected specs

If `docs/REGISTER.md` exists:

1. Get all changed files on this branch:
   ```bash
   BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
   git diff $BASE...HEAD --name-only
   ```

2. Read the register and map changed files to owning specs
3. Read each owning spec and check its status

Present:
```
## Specs affected by this branch

| Spec | Current Status | Action needed |
|------|---------------|---------------|
| <name> | draft | Run `/consolidate` to reconcile to `active` |
| <name> | stale | Run `/consolidate` to reconcile drift |
| <name> | active | OK — no action needed |
```

If any specs are still `draft` or `stale`, flag this — they should be at `active` before creating a PR. `/consolidate` reconciles `draft → active` (or `stale → active`).

### Step 3: Run health check

If `scripts/health-check.sh` exists:

```bash
bash scripts/health-check.sh "$(git rev-parse --show-toplevel)" 2>&1
```

Present results. If issues are found:
> "Health check found issues. Fix these before creating the PR? Or proceed anyway?"

### Step 4: Reconcile specs to `active` via `/consolidate`

For each spec affected by this branch, ensure its status is `active` (matches current code). Under the simplified state machine, status flips happen automatically:

- `/consolidate` flips `draft` → `active` when reconciliation succeeds.
- `/health-check` flips `active` → `stale` when drift is detected.

**If any affected spec is at `draft` or `stale`**, automatically invoke `/consolidate` to reconcile. `/consolidate` will run its normal interactive flow (presenting reconciliation plans for approval, regenerating AUTO sections, harvesting decisions). Don't ask the user whether to run it — running `/consolidate` is the mechanism by which `/finish` honors its name.

If all affected specs are already at `active`, this step is a no-op (skip silently).

Skip this step entirely for documentation-only changes (no source files in the diff).

### Step 5: Security review

Check if any changed files are agent-facing:
- `.claude/hooks/**`, `.claude/skills/**`, `skills/**`, `.githooks/**`, `scripts/**`
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`

`/security-review` is **mandatory** in the current general-release pipeline.
Always invoke it, regardless of whether agent-facing files appear in the diff.
The skill self-gates and exits fast when no injection surface is present, so the
cost is near zero on changes that genuinely need nothing.

### Step 5.5: Pre-PR local CI gate

Determine the local check command from the project's declared testing shape. If
the testing-shape spec is present but invalid, stop; do not fall back to
`scripts/ci-checks.sh`. If the spec is absent, `/finish` keeps its narrow
pre-PR behaviour and skips this local gate instead of adding package/Makefile
discovery:

```bash
TEST_SPEC="docs/specs/test-infrastructure.spec.md"
RTC_ERR=$(mktemp)
if CFG=$(bash scripts/read-test-config.sh "$TEST_SPEC" 2>"$RTC_ERR"); then
  TEST_CMD=$(printf '%s\n' "$CFG" | grep -m1 '^default-command=' | cut -d= -f2-)
else
  if [ -f "$TEST_SPEC" ]; then
    echo "ERROR: $TEST_SPEC is present but invalid; do not fall back to scripts/ci-checks.sh." >&2
    cat "$RTC_ERR" >&2
    rm -f "$RTC_ERR"
    exit 1
  fi
  TEST_CMD=""
fi
rm -f "$RTC_ERR"

if [ -n "$TEST_CMD" ]; then
  eval "$TEST_CMD"
else
  echo "no declared default-command — skipping pre-PR gate"
fi
```

Run **only** `default-command` — never the `opt-in-commands` tiers. If it exits
non-zero, present the failures and fix them before proceeding — the PR should be
green from its first push.

### Step 5.8: Tracker closure-intent audit

Before invoking `/pr`, resolve the active tracker issue using the same priority
order as `/pr`: `$ISSUE`, then the current branch slug's design spec
`related-issue:` frontmatter, then no issue. Present a concise audit:

```text
Tracker closure intent:
- Will close: #<issue> | none
- References only: #<issue-list> | none
- Provider verification: supported | unsupported | unknown
```

For `github`, provider verification is `supported` when exactly one closeable
issue will be rendered with a GitHub closing keyword in `/pr`'s `## Tracker`
section. For `azure-devops`, provider verification is `unknown` until
post-merge `/cleanup`: `/pr` will link the work item, but Arboretum must not
claim closure until the read-only linked-work-item state check runs.

If no tracker issue is resolved, warn clearly but continue when the user wants
a trackerless PR.

### Step 6: Create PR

Invoke the `/pr` skill to create the pull request through `$SHIP_BACKEND`. It handles:
- Health check summary
- Spec context
- Pushing the branch
- Creating the PR via `gh pr create` for `github`
- Creating the PR via `az repos pr create` for `azure-devops`

Present the PR URL when done.

### Step 6.3: Hand off to `/land`

After the PR is created, invoke `/land <pr-number>` to drive it to merge-ready
through the same backend. For `github`, `/land` runs the existing CI/reviewer
poll loop. For `azure-devops`, `/land` uses Azure Repos state and policy checks
and hands off any unsupported reviewer-thread automation explicitly. `/land`
runs its own asynchronous loop where supported; `/finish` does not block on it.

### Step 7: Suggest next steps

After the PR is created:
> "PR created: <url>
>
> After it's approved and merged, run `/cleanup` to switch to main, pull, and delete this branch. The ship tail is `/cleanup` → `/reflect` → `/handoff`; `/reflect` Q5 is the canonical handoff invocation (queues `next-up` against an issue that is actually-open post-merge)."

At exit, if `$ISSUE` is set, log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /finish exited
fi
```

## Unified ship tail

The ship tail sequence is: verify → identify affected specs → health-check →
`/consolidate` → `/security-review` → local CI gate → backend-aware `/pr` →
backend-aware `/land`.

The model-level differences that matter to `/finish` are upstream:
everything-else pre-build work produces an in-flight design spec, and `/design`
may have already committed approved durable intent/seam edits. Those choices
change what `/consolidate` reconciles in Step 4, not what `/finish`
orchestrates:

- Step 2's "specs affected by this branch" list will, for everything-else changes, always include the design spec at `docs/superpowers/specs/`; that spec drives `/consolidate`'s behaviour but is not itself a governed spec.
- Step 4's `/consolidate` invocation is the reconciler for generated/evidence sections and built-state updates. The "If any affected spec is at `draft` or `stale`" check still applies — `/consolidate` flips `draft → active` when reconciliation succeeds.
- Step 5's security review is mandatory — invoke `/security-review` rather than offering it optionally. The skill self-gates and exits fast when no injection surface is present.

These notes explain the current release pipeline; the procedure steps above
remain authoritative.

## Important

- This skill orchestrates existing skills (`/consolidate`, `/security-review`, `/pr`, `/land`). It doesn't duplicate their internals — it calls them in the right order.
- **`/handoff` is no longer invoked here** (WS1 D8). The pre-merge handoff in the prior Step 6.5 queued `next-up` against the issue the PR was about to close — a race that resolved incoherently. Handoff now fires post-merge from `/reflect` Q5, which is the single canonical handoff invocation in the ship tail.
- **`/land` is merge-readiness-only.** It does not close tracker items; post-merge tracker verification and any safe fallback close belong to `/cleanup`.
- Steps are sequential and each depends on the previous one. Don't skip ahead.
- If the user wants to create a PR without reconciling spec status via `/consolidate` or running health checks, let them — this is guidance, not a gate. But note what was skipped.
- For documentation-only branches (no source code changes), there is typically no spec-status reconciliation needed; `/security-review` still runs and self-gates when no injection surface is present.

$ARGUMENTS
