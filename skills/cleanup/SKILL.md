---
name: cleanup
owner: workflow-unification
description: Post-merge cleanup — switch to main, pull latest, delete the merged feature branch, and verify spec status. Use after a PR has been merged.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob
layer: 0
---

# Cleanup

Handles post-merge housekeeping so the working directory is ready for the next task.

## When to use

- After a PR has been merged
- User says "it's merged", "PR was merged", "clean up"
- At the start of a new session when the previous branch's PR was merged

## Procedure

### Stage logging

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /cleanup entered
fi
```

At exit (when the procedure completes), log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /cleanup exited
fi
```


### Step 1: Detect merged state

Check the current branch and its PR status:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $BRANCH"
```

If on `main` or `master`, check for stale local branches:
```bash
git branch --merged main | grep -v '^\*\|main\|master'
```

If on a feature branch, check if its PR was merged:
```bash
gh pr list --head "$BRANCH" --state merged --json number,title,mergedAt
```

If the PR is not merged yet:
> "PR for branch `<branch>` hasn't been merged yet. Did you mean to run `/finish` to create the PR?"

Stop here — don't clean up an unmerged branch.

### Step 2: Switch to main

```bash
git checkout main
git pull
```

Report what was pulled (new commits, if any).

### Step 3: Delete the feature branch

```bash
git branch -d <branch-name>
```

Use `-d` (not `-D`) — this is safe because the branch is already merged. If it fails, the branch wasn't fully merged and something may be wrong.

If there's a remote tracking branch:
```bash
git remote prune origin
```

### Step 4: Verify spec status

If `docs/REGISTER.md` exists:

1. Read the register.
2. Confirm that specs touched by the merged PR are at status `active` (the new state machine: `draft / active / stale`).
3. If any spec is still at `draft`, suggest running `/consolidate` to flip it to `active`. If any spec is at `stale`, suggest running `/consolidate` to reconcile drift.
4. No manual promotion needed — `/consolidate` handles status flips automatically.

### Step 5: Suggest reflection

> "Before moving on — want to run `/reflect` to capture what you learned from this work?"

If the user declines, move on immediately. Do not push.

### Step 6: Suggest next steps

> "Cleanup complete. On main with latest changes.
>
> Ready for the next task? Start with a change request and I'll route you through the workflow."

## Important

- **Safe deletion only.** Use `git branch -d`, not `-D`. If the branch wasn't fully merged, something is wrong — don't force-delete.
- **Check before deleting.** Always verify the PR was actually merged before cleaning up.
- **Spec status is automatic.** The state machine has only three states (`draft / active / stale`); flips happen via `/consolidate` and `/health-check`. No manual promotion step exists.
- This skill can be auto-invoked by Claude (via SessionStart) if it detects the user is on a branch whose PR was merged.

$ARGUMENTS
