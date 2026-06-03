---
name: cleanup
owner: workflow-unification
description: Post-merge cleanup — verify merge state, safely remove the merged local branch/session worktree, and verify spec status. Use after a PR has been merged.
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

Capture the exact session worktree and branch before any checkout or cleanup command:

```bash
SESSION_WORKTREE="$(git rev-parse --show-toplevel)"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Session worktree: $SESSION_WORKTREE"
echo "Current branch: $BRANCH"
```

If on `main` or `master`, check for stale local branches:
```bash
DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
git branch --merged "$DEFAULT_BRANCH" | grep -v '^\*\|main\|master'
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

After merge/completion is confirmed and before switching to the default branch, read the
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

### Step 2: Verify spec status before local cleanup

If `docs/REGISTER.md` exists:

1. Read the register.
2. Confirm that specs touched by the merged PR are at status `active` (the new state machine: `draft / active / stale`).
3. If any spec is still at `draft`, suggest running `/consolidate` to flip it to `active`. If any spec is at `stale`, suggest running `/consolidate` to reconcile drift.
4. No manual promotion needed — `/consolidate` handles status flips automatically.

Do this before invoking the local cleanup helper, because the helper may remove
the active session worktree as its final action.

### Step 3: Run local cleanup helper

Do not delete branches or worktrees directly in the skill. Delegate the local
destructive action to the audited helper:

```bash
bash scripts/cleanup-merged-session.sh --branch "$BRANCH" --worktree "$SESSION_WORKTREE" --remove-active-worktree
```

The helper switches an appropriate control worktree to the remote default branch, runs
`git pull --ff-only`, verifies provider merge proof plus local SHA containment,
tries `git branch -d` first, and only then may use `git branch -D` for a
provider-proven squash-merged local branch.

The helper may force-delete only a provider-proven squash-merged local branch.
It must never delete remote branches, protected branches, dirty/locked
worktrees, or unrelated session worktrees.

If the helper prints:

```text
session=terminal reason=active-worktree-removed action=end-or-reopen-session
```

the active session worktree was removed. This is the final filesystem action.
Tell the user to end this session or open a fresh session from a valid checkout;
do not run further commands from the removed path.

### Step 3.5: Surface release pending state

Use the merged PR metadata read in Step 1.5. If the PR body contains
`release-state: pending`, include this in the cleanup result:

> "Cleanup complete. Release remains pending; run `scripts/prepare-release-package.sh` from main when the Release Package is ready."

Do not run the release-package helper from `/cleanup`; cleanup only preserves
the handoff. If the active session worktree was removed, this is still safe to
report as final guidance, but do not run any further commands from the removed
path.

### Step 4: Suggest reflection

> "Before moving on — want to run `/reflect` to capture what you learned from this work?"

If the user declines, move on immediately. Do not push.

Skip this step when the active session worktree was removed; the final response
should instead tell the user to end or reopen the session.

### Step 5: Suggest next steps

> "Cleanup complete. On the default branch with latest changes.
>
> Ready for the next task? Start with a change request and I'll route you through the workflow."

Skip this step when the active session worktree was removed.

## Important

- **Helper owns local destructive cleanup.** Do not run raw branch/worktree deletion commands in the skill. Use `scripts/cleanup-merged-session.sh`.
- **Force-delete exemption is narrow.** The helper may use `git branch -D` only after provider-merged state and local-SHA-contained-by-provider-head proof. A `[gone]` upstream is never proof.
- **Active session worktree removal is terminal.** If the active session worktree is removed, stop and tell the user to end or reopen the session before doing more work.
- **Check before deleting.** Always verify the PR was actually merged before cleaning up.
- **Spec status is automatic.** The state machine has only three states (`draft / active / stale`); flips happen via `/consolidate` and `/health-check`. No manual promotion step exists.
- This skill can be auto-invoked by Claude (via SessionStart) if it detects the user is on a branch whose PR was merged.

$ARGUMENTS
