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

Resolve the configured repo backend before checking provider PR state:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
CLEANUP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export CLEANUP_BACKEND
roadmap_require_backend "$CLEANUP_BACKEND" || exit 1
```

Check the current branch:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $BRANCH"
```

If on `main` or `master`, check for stale local branches:
```bash
git branch --merged main | grep -v '^\*\|main\|master'
```

If on a feature branch, check if its PR was merged through the configured
backend:

For `github`:

```bash
MERGED_PR_JSON="$(gh pr list --head "$BRANCH" --state merged --json number,title,mergedAt)"
MERGED_PR_COUNT="$(printf '%s\n' "$MERGED_PR_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
```

For `azure-devops`:

```bash
MERGED_PR_JSON="$(az repos pr list \
  --source-branch "$BRANCH" \
  --status completed \
  --output json)"
MERGED_PR_COUNT="$(printf '%s\n' "$MERGED_PR_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
```

For either backend, require exactly one merged/completed PR before continuing:

```bash
case "$MERGED_PR_COUNT" in
  0)
    echo "PR for branch '$BRANCH' hasn't been merged yet. Did you mean to run /finish to create the PR?"
    exit 0
    ;;
  1) ;;
  *)
    echo "Found multiple merged/completed PRs for branch '$BRANCH'. Stop and inspect the configured tracker backend before cleanup."
    exit 1
    ;;
esac

case "$CLEANUP_BACKEND" in
  github)
    MERGED_PR_NUMBER="$(printf '%s\n' "$MERGED_PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("number",""))')"
    ;;
  azure-devops)
    MERGED_PR_NUMBER="$(printf '%s\n' "$MERGED_PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("pullRequestId",""))')"
    ;;
esac

[ -n "$MERGED_PR_NUMBER" ] || {
  echo "Merged/completed PR lookup returned no PR number. Stop and inspect the configured tracker backend before cleanup."
  exit 1
}
```

Stop here — don't clean up an unmerged branch.

On `azure-devops`, `completed` is the merged PR state. If no completed PR is
found, do not fall back to GitHub or infer from local branch ancestry; stop with
the same unmerged-branch message.

### Step 1.5: Verify tracker closure after merge

After merge/completion is confirmed and before switching to main, read the
merged PR metadata through the configured backend:

```bash
PR_JSON="$(roadmap_tracker_pr_show "$MERGED_PR_NUMBER" --json number,body,state,mergedAt)"
```

Resolve the related tracker issue in this priority order:

1. `$ISSUE`, when set.
2. A close/link line in the PR `## Tracker` section (`Closes #N` or
   `Linked work item: #N`).
3. No issue known.

If an issue is known, ask the neutral helper for closure status:

```bash
CLOSURE_STATUS="$(roadmap_tracker_pr_closure_status "$MERGED_PR_NUMBER" "$ISSUE")"
```

Interpret the key/value result:

- `intent=close` and `verification=supported`: read current issue state with
  `roadmap_tracker_issue_show "$ISSUE" --json state`. If the issue is still
  open, close it through:
  ```bash
  roadmap_tracker_issue_close "$ISSUE" --reason completed --comment "Closed after merged PR #$MERGED_PR_NUMBER declared close intent."
  ```
- `intent=reference` or `intent=none`: leave the tracker issue open and report
  that the PR did not declare close intent.
- `verification=unsupported`: leave the tracker issue open and report the
  provider limitation explicitly. For this slice, Azure DevOps falls here.
- `verification=unknown`: leave the tracker issue open and report that manual
  follow-up is needed.

Never call `gh issue close` or `az boards work-item update` directly for
ship-tail closure. `/cleanup` closes only through
`roadmap_tracker_issue_close`, and only when the neutral closure-status helper
reports a supported close intent.

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
