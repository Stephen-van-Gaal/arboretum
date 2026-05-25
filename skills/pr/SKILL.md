---
name: pr
owner: git-workflow-tooling
description: Create a pull request with spec-aware body, health-check summary, and security review suggestion. Use when ready to open a PR for the current branch.
disable-model-invocation: false
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
argument-hint: [--draft] [--reviewer <user>] [gh pr create options...]
layer: 0
---

# Create Pull Request

Create a spec-aware pull request for the current feature branch.

## Procedure

### Stage logging

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /pr entered
fi
```

At exit (when the procedure completes), log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /pr exited
fi
```


### 1. Check branch

Verify you are NOT on `main` or `master`. If on a protected branch, stop and tell the user:
> "You're on [branch]. Create a feature branch first: `git checkout -b feat/your-feature`"

### 2. Detect base branch

```bash
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
BASE="${BASE:-main}"
```

Use `$BASE` for all subsequent diff/log commands.

### 3. Gather context

Run these in parallel:

- `git log $BASE..HEAD --oneline` — commits on this branch
- `git diff $BASE...HEAD --name-only` — all changed files
- `git status --short` — any uncommitted work
- `git rev-parse --abbrev-ref @{upstream} 2>/dev/null` — remote tracking status

If there is uncommitted work, warn the user:
> "You have uncommitted changes. Commit or stash them before creating a PR?"

Wait for user response before proceeding.

### 4. Run health check

If `scripts/health-check.sh` exists and is executable, run it:

```bash
bash scripts/health-check.sh "$(git rev-parse --show-toplevel)" 2>&1
```

Capture the output. If it reports issues, present them and ask:
> "Health check found issues (see above). Proceed anyway, or fix first?"

### 5. Identify spec context

If `docs/REGISTER.md` exists:

1. Read the register
2. For each changed file, find which spec owns it (match against the Spec Index table's "owns" column)
3. For each owning spec, extract its status
4. Note any changed files not listed in any spec's ownership

Build a specs table:

```markdown
| Spec | Status | Files changed |
|---|---|---|
| <spec-name> | <status> | <count> |
```

If `docs/REGISTER.md` does not exist, skip this section entirely.

### 6. Suggest security review

Check if any changed files match these paths:
- `.claude/hooks/**`
- `.claude/skills/**`
- `skills/**`
- `.githooks/**`
- `scripts/**`
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`

If any match, suggest:
> "This PR modifies agent-facing code. Consider running `/security-review` before creating the PR. Proceed without review?"

This is a suggestion, not a gate. If the user declines, proceed.

### 7. Push

If the branch does not track a remote:
```bash
git push -u origin $(git rev-parse --abbrev-ref HEAD)
```

If it already tracks a remote:
```bash
git push
```

### 8. Create PR

Draft the PR title and body:

- **Title:** Concise, under 70 characters, summarizing the branch's changes
- **Body:** Use this structure:

```
## Summary
<1-3 bullet points summarizing what changed and why>

## Specs
<spec table from step 5, or omit section if no REGISTER.md>

## Health Check
<"All checks passed" or summary of issues, or "N/A — no health-check script found">

## Test Plan
<bulleted checklist of how to verify the changes>
```

Create the PR:
```bash
gh pr create --title "<title>" --body "<body>" $EXTRA_ARGS
```

Where `$EXTRA_ARGS` are any arguments passed via `$ARGUMENTS` (e.g., `--draft`, `--reviewer octocat`).

Present the PR URL to the user.

## Graceful Degradation

- **No `REGISTER.md`:** Skip the Specs section in the PR body
- **No `health-check.sh`:** Show "N/A — no health-check script found" in Health Check section
- **No `gh` CLI:** Error with: "The `gh` CLI is required. Install it: https://cli.github.com/"
- **No remote:** Error with: "No remote configured. Add one with `git remote add origin <url>`"
- **Early-phase project:** All governance features degrade gracefully — PR creation always works

$ARGUMENTS
