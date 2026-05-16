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

### Step 1: Verify implementation state

Check the current state:

```bash
git status --short
git log $(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)..HEAD --oneline
```

Report:
- **Uncommitted changes:** If any, warn: "You have uncommitted changes. Commit them first?"
- **Commits on branch:** List them so the user can confirm the work is complete
- **Current branch:** Confirm it's a feature branch

If there are uncommitted changes, wait for the user to resolve them before proceeding.

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

### Step 5: Security review (if applicable)

Check if any changed files are agent-facing:
- `.claude/hooks/**`, `.claude/skills/**`, `skills/**`, `.githooks/**`, `scripts/**`
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`

If any match:
> "This branch modifies agent-facing code. Run `/security-review` before creating the PR? (Recommended but not required)"

If the user agrees, run the security review. If they decline, proceed.

### Step 5.5: Pre-PR local CI gate

If `scripts/ci-checks.sh` exists, run it:

```bash
bash scripts/ci-checks.sh
```

If it exits non-zero, present the failures and fix them before proceeding —
the PR should be green from its first push. If `ci-checks.sh` does not exist,
note "no local check entrypoint — skipping pre-PR gate" and continue.

### Step 6: Create PR

Invoke the `/pr` skill to create the pull request. It handles:
- Health check summary
- Spec context
- Pushing the branch
- Creating the PR via `gh pr create`

Present the PR URL when done.

### Step 6.3: Hand off to `/land`

After the PR is created, invoke `/land <pr-number>` to drive it to merge-ready
(poll CI + reviewers, triage and action feedback, tiered merge handoff). `/land`
runs its own asynchronous loop; `/finish` does not block on it.

### Step 6.5: Capture session handoff

After the PR is created, prompt once:

> "Which issue should be queued as `next-up` for the next session? (Issue number, or 'skip')"

If the user gives a number, invoke `/handoff <N>`. The `/handoff` skill is the canonical writer — it manages the `next-up` GitHub label, enforces exclusivity, and refreshes the local cache. Do not call `gh` directly here.

If the user declines or skips, move on silently. This step is **advisory**: never block the rest of the flow.

If `gh` is missing or unauthenticated, `/handoff` will surface its own install/auth instructions and refuse — surface that error to the user and continue.

### Step 7: Suggest next steps

After the PR is created:
> "PR created: <url>
>
> After it's approved and merged, run `/cleanup` to switch to main, pull, and delete this branch."

## Important

- This skill orchestrates existing skills (`/consolidate`, `/security-review`, `/pr`, `/land`, `/handoff`). It doesn't duplicate their internals — it calls them in the right order.
- Steps are sequential and each depends on the previous one. Don't skip ahead.
- If the user wants to create a PR without reconciling spec status via `/consolidate` or running health checks, let them — this is guidance, not a gate. But note what was skipped.
- For documentation-only branches (no source code changes), there is typically no spec-status reconciliation needed; skip security review and go straight to health check and PR.

$ARGUMENTS
