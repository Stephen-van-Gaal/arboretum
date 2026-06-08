---
script: scripts/cleanup-merged-session.sh
version: 1.1
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
- `--plan` - Optional. Read-only. Runs every safety gate and emits a `plan=ready` or `plan=blocked` status line **without mutating** the repository. Mutually exclusive with `--execute`.
- `--execute` - Optional. The default when no mode flag is given. Re-runs every gate and then performs branch/worktree cleanup. Mutually exclusive with `--plan`.
- `--help` - Prints usage and exits 0.

Unknown arguments exit 2. Supplying both `--plan` and `--execute` exits 2.

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
- `plan=ready branch=<name> worktree=<path> branch-mode=safe|force-squash remove-worktree=yes|no active=yes|no`
- `plan=blocked reason=<reason>`

Under `--plan`, gate failures (exit 1) emit `plan=blocked reason=<reason>` using the same reason vocabulary as `cleanup=skipped`, and no mutation occurs. Invocation and tool setup failures (exit 2 — `bad-arg`, `mode-conflict`, `missing-roadmap-lib`, `not-git-worktree`, `unsupported-backend`) always emit `cleanup=skipped reason=<reason>` regardless of mode — a setup error never masquerades as a `plan=blocked` safety refusal. `--plan` is read-only for **any** target, including the active worktree, so it never refuses with `active-worktree-needs-flag` (that gate is `--execute`-only). Safety refusals exit `1`. Successful cleanup (or a ready plan) exits `0`.

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
- **CLI-11: Plan ready (safe).** `--plan` on a provider-merged merge-commit branch emits `plan=ready … branch-mode=safe` and mutates nothing.
- **CLI-12: Plan ready (squash).** `--plan` on a squash-merged provider-proven branch emits `plan=ready … branch-mode=force-squash` and mutates nothing.
- **CLI-13: Plan blocked.** `--plan` on a dirty or unproven target emits `plan=blocked reason=<reason>` (exit 1) and mutates nothing.
- **CLI-14: Mode exclusion.** `--plan --execute` together exits 2.
- **CLI-15: Execute default.** No mode flag behaves as `--execute` (existing CLI-5…CLI-10 cases).

## Versioning

- **1.0** - initial provider-proven local branch and worktree cleanup helper contract for issue #490 (2026-06-03).
- **1.1** - additive read-only `--plan` mode and `plan=ready`/`plan=blocked` tokens for driver dry-run; `--execute` default preserved (issue #644, 2026-06-07).
