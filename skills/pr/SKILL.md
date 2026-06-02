---
name: pr
owner: git-workflow-tooling
description: Create a pull request with spec-aware body, health-check summary, and security review suggestion through the configured repo backend. Use when ready to open a PR for the current branch.
disable-model-invocation: false
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
argument-hint: "[--draft] [--reviewer <user>] [provider PR options...]"
layer: 0
---

# Create Pull Request

Create a spec-aware pull request for the current feature branch using the
project's configured repo backend. `github` preserves the existing `gh` path;
`azure-devops` uses Azure Repos through the Azure CLI.

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


### 0. Select repo backend

Read the configured backend before any PR-provider work:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
SHIP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export SHIP_BACKEND
```

Supported repo backends:

- `github` - create the PR with `gh pr create`.
- `azure-devops` - create the PR with `az repos pr create`.

For any other value, stop and tell the user:
> "Unsupported PR backend: <backend>. Supported backends: github, azure-devops."

Run the matching backend-access guard before creating the PR:

```bash
roadmap_probe_backend_access "$SHIP_BACKEND" "$PROJECT_DIR" || exit 1
```

The live-access probe checks local CLI/config prerequisites and confirms this
agent process can reach the selected provider API from the target project root.
If the probe fails under Codex, surface its backend-specific network
configuration guidance before attempting any `gh pr create` or
`az repos pr create` command.

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

Create the PR through the selected backend.

For `github`:

```bash
gh pr create --title "<title>" --body "<body>" $EXTRA_ARGS
```

Where `$EXTRA_ARGS` are any arguments passed via `$ARGUMENTS` (for example
`--draft`, `--reviewer octocat`, or another `gh pr create` option).

For `azure-devops`, map the common Arboretum arguments before passing through
provider-specific options:

- `--draft` -> `--draft true`
- `--reviewer <user>` -> `--reviewers <user>`
- `$ISSUE` set -> `--work-items "$ISSUE"` so the PR links to the active work item

Then create the PR:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
AZ_ARGS=(
  repos pr create
  --source-branch "$BRANCH"
  --target-branch "$BASE"
  --title "<title>"
  --description "<body>"
  --output json
)
[ -n "${ISSUE:-}" ] && AZ_ARGS+=(--work-items "$ISSUE")
PR_JSON="$(az "${AZ_ARGS[@]}" ${AZURE_EXTRA_ARGS:-})"
PR_ID="$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pullRequestId",""))')"
```

Use `roadmap_ado_organization` / `roadmap_ado_project` from the sourced helper
library when constructing fallback URLs so the link matches Arboretum's active
ADO context, even when Azure CLI used repo auto-detection or git config rather
than global defaults. Present a browser URL, not the Azure Repos REST/API `url`
field. Prefer the web link Azure returns in `_links.web.href`; if the create
response does not include links, query the PR with `--include-links` before
falling back to a constructed portal URL from helper values and PR metadata:

```bash
PR_WEB_URL="$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("_links",{}).get("web",{}).get("href",""))' 2>/dev/null)"
if [ -z "$PR_WEB_URL" ]; then
  PR_WEB_URL="$(az repos pr list --status all --include-links \
    --query "[?pullRequestId==\`$PR_ID\`]._links.web.href | [0]" -o tsv)"
fi
if [ -z "$PR_WEB_URL" ]; then
  ORG_URL="$(roadmap_ado_organization 2>/dev/null || true)"
  PROJECT="$(roadmap_ado_project 2>/dev/null || true)"
  REPO_NAME="$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repository",{}).get("name",""))')"
  PROJECT="${PROJECT:-$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repository",{}).get("project",{}).get("name",""))')}"
  ORG_URL="${ORG_URL:-$(printf '%s\n' "$PR_JSON" | python3 -c 'import json,sys,re; d=json.load(sys.stdin); u=d.get("repository",{}).get("project",{}).get("url",""); m=re.match(r"(https://dev\.azure\.com/[^/]+)", u); print(m.group(1) if m else "")')}"
  if [ -n "$ORG_URL" ] && [ -n "$PROJECT" ] && [ -n "$REPO_NAME" ] && [ -n "$PR_ID" ]; then
    PR_WEB_URL="$(python3 - "$ORG_URL" "$PROJECT" "$REPO_NAME" "$PR_ID" <<'PY'
from urllib.parse import quote
import sys
org, project, repo, pr = sys.argv[1:5]
print(f"{org.rstrip('/')}/{quote(project, safe='')}/_git/{quote(repo, safe='')}/pullrequest/{quote(pr, safe='')}")
PY
)"
  fi
fi
if [ -z "$PR_WEB_URL" ]; then
  echo "Azure Repos PR $PR_ID was created, but I couldn't derive a browser URL from the active ADO context. Open it from Azure Repos."
  exit 0
fi
printf '%s\n' "$PR_WEB_URL"
```

Present the PR URL to the user.

## Graceful Degradation

- **No `REGISTER.md`:** Skip the Specs section in the PR body
- **No `health-check.sh`:** Show "N/A — no health-check script found" in Health Check section
- **Backend prerequisites unavailable:** Surface `roadmap_require_backend`'s diagnostic
  for the selected backend. For `github`, this is the `gh` install/auth path. For
  `azure-devops`, this is the Azure CLI / Azure DevOps extension / configured
  defaults path.
- **No remote:** Error with: "No remote configured. Add one with `git remote add origin <url>`"
- **Early-phase project:** All governance features degrade gracefully — PR creation always works

$ARGUMENTS
