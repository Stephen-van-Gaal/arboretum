---
script: scripts/cleanup-merged-session.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/cleanup
  - type: script
    name: scripts/_smoke-test-cleanup-merged-session.sh
related-designs:
  - docs/superpowers/specs/2026-06-03-cleanup-session-worktree-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/cleanup-merged-session.sh`

## Surface

`scripts/cleanup-merged-session.sh` is the only automatic destructive local cleanup surface for `/cleanup`. It may remove a local branch and the exact target worktree only after proving that the branch was merged by the configured tracker provider and that the local branch tip is contained in the provider's recorded PR head/source commit.

The helper is intentionally narrow: it never deletes remote branches, never treats a `[gone]` upstream as proof, and never uses broad worktree cleanup. Its force-delete exemption is only for provider-proven squash-merged local branches where `git branch -d` cannot prove ancestry.

## Protocol

### Arguments

```bash
bash scripts/cleanup-merged-session.sh [--branch <name>] [--worktree <path>] [--remove-active-worktree]
```

- `--branch <name>` - Optional. Local branch to consider for deletion. Defaults to the current branch in the session root. `main`, `master`, empty branch names, and detached `HEAD` are refused.
- `--worktree <path>` - Optional. Exact worktree path to consider for removal. Defaults to the current repository root.
- `--remove-active-worktree` - Optional. Allows the helper to remove the active session worktree only as its terminal action after all safety gates pass and removal succeeds.
- `--help` - Prints usage and exits 0.

Unknown arguments exit 2.

### Required gates

- reject `main` and `master`
- reject dirty target worktrees
- reject locked worktrees
- reject target worktrees that are attached to a branch other than `--branch`
- verify provider merged/completed PR state for the remote default target branch
- verify the local branch SHA is equal to or an ancestor of the provider PR head/source SHA
- try `git branch -d` before `git branch -D`
- use `git branch -D` only for provider-proven squash merge cleanup
- remove only the exact clean target worktree
- never delete remote branches

### Status tokens

The script writes one token-oriented status line per decision:

- `cleanup=skipped reason=<reason>`
- `branch=deleted mode=safe`
- `branch=deleted mode=force-squash`
- `worktree=removed active=true|false`
- `worktree=kept reason=<reason>`
- `session=terminal reason=active-worktree-removed action=end-or-reopen-session`

Invocation and tool setup failures exit `2`. Safety refusals exit `1`. Successful cleanup exits `0`.

## Test surface

- **CLI-1: Help and contract shape.** `--help` exits 0 and names `cleanup-merged-session`.
- **CLI-2: Protected branch refusal.** `main` and `master` emit `cleanup=skipped reason=protected-branch` and exit 1.
- **CLI-3: Dirty worktree refusal.** A dirty target worktree emits `cleanup=skipped reason=dirty-worktree` and exits 1.
- **CLI-4: Worktree branch binding.** A clean target worktree attached to a different branch emits `cleanup=skipped reason=worktree-branch-mismatch` and exits 1.
- **CLI-5: Safe deletion.** A provider-merged branch that is already mergeable by `git branch -d` emits `branch=deleted mode=safe`.
- **CLI-6: Squash deletion.** A provider-merged branch whose local SHA is contained by the provider PR head/source SHA but not by local `main` emits `branch=deleted mode=force-squash`.
- **CLI-7: Target-base proof.** Provider proof for a merged/completed PR whose target branch is not the remote default branch is rejected before branch deletion.
- **CLI-8: Unproven local commits.** A branch whose local SHA is not contained by the provider PR head/source SHA emits `cleanup=skipped reason=unproven-local-commits` and exits 1.
- **CLI-9: Active worktree terminal action.** When the exact active linked worktree is safely removed, the helper emits `worktree=removed active=true` and `session=terminal reason=active-worktree-removed action=end-or-reopen-session`.
- **CLI-10: Active removal failure.** When active worktree removal fails, the helper emits `worktree=kept reason=remove-failed`, exits 1, and does not emit the terminal session token.

## Versioning

- **1.0** - initial provider-proven local branch and worktree cleanup helper contract for issue #490 (2026-06-03).
