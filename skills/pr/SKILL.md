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
source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
BASE="$(workspace_base_ref --fetch)"   # pr is ship-tail pre-PR -> --fetch for a fresh base
```

Use `$BASE` for all subsequent diff/log commands.

### 3. Gather context

Run these in parallel:

- `git log "$BASE"..HEAD --oneline` — commits on this branch
- `git diff "$BASE"...HEAD --name-only` — all changed files
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

Health-check is deliberately **not** read from the pipeline-context ledger — `/pr` re-runs it fresh to catch drift introduced between `/consolidate` and `/pr` (pipeline-context-ledger design D3). Only the spec-index is served from the ledger here.

Capture the output. If it reports issues, present them and ask:
> "Health check found issues (see above). Proceed anyway, or fix first?"

### 5. Identify spec context

If `docs/REGISTER.md` exists:

1. Read the register's Spec Index with a bounded section read (it carries both ownership and status, so no per-spec read is needed). Prefer the pipeline-context ledger (keyed on this HEAD, seeded at `/finish`); fall back to the live section read on a miss:
   ```bash
   bash scripts/read-pipeline-context.sh spec_index 2>/dev/null \
     || bash scripts/read-doc-section.sh docs/REGISTER.md "Spec Index"
   ```
2. For each changed file, find which spec owns it (match against the Spec Index table's `Owns` column)
3. Read each owning spec's status from the same Spec Index `Status` column
4. Note any changed files not listed in any spec's ownership

Build a specs table:

```markdown
| Spec | Status | Files changed |
|---|---|---|
| <spec-name> | <status> | <count> |
```

If `docs/REGISTER.md` does not exist, skip this section entirely.

### 5.5 Resolve tracker closure intent

Before drafting the PR body, resolve the active tracker issue in this priority
order:

1. `$ISSUE`, when set.
2. The design spec matching the current branch slug under
   `docs/superpowers/specs/*-<slug>-design.md`, using its `related-issue:`
   frontmatter.
3. No issue found.

Use the same branch-slug convention as `scripts/refresh-stage-cache.sh`: strip
the prefix through the first `/`, then also try the slug with a trailing
`-build` removed. Do not invent a second branch naming rule.

If exactly one non-epic tracker issue is resolved, mark it as closeable for
GitHub PRs. If the candidate is an epic, or if multiple issues would be
referenced, separate close intent from reference-only intent and ask before
using any closing keyword. Do not auto-close epics.

For `azure-devops`, keep the existing work-item link behaviour and make the
closure state explicitly post-merge/read-only: `/pr` links the work item, but it
does not claim that linkage closes the item. `/cleanup` verifies the linked work
item state after merge.

### 6. Suggest security review

Check if any changed files match these paths:
- `.claude/hooks/**`
- `.claude/skills/**`
- `skills/**`
- `.githooks/**`
- `scripts/**`
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`

If any match, suggest:
> "This PR modifies agent-facing code. Consider running `/ai-surface-review` before creating the PR. Proceed without review?"

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

When invoked from `/finish` on the GitHub backend, `--draft` is the default
ship-tail mode unless the user explicitly requested a ready PR. Direct `/pr`
arguments remain authoritative: if the user runs `/pr` without `--draft`, create
the PR as requested, then run the non-draft remote readiness gate below before
requesting reviewers.

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

## Tracker
<closure or linkage statement from Step 5.5>
```

Create the PR through the selected backend.

For `github`:

When Step 5.5 resolved exactly one closeable issue, the Tracker section MUST be:

```markdown
## Tracker
Closes #<issue>
```

When no tracker issue is resolved, the Tracker section MUST be:

```markdown
## Tracker
No tracker issue resolved.
```

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

When Step 5.5 resolved one issue, the Tracker section MUST be:

```markdown
## Tracker
Linked work item: #<issue>
Closure verification: pending post-merge cleanup
```

When no tracker issue is resolved, render:

```markdown
## Tracker
No tracker issue resolved.
```

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

### 8.5 Capture first remote readiness

After PR creation, capture the first remote readiness snapshot. For draft PRs,
allow the draft-clean state:

```bash
PR_NUMBER="${PR_ID:-$(gh pr view --json number --jq .number 2>/dev/null)}"
if printf '%s\n' "${EXTRA_ARGS:-}" | grep -q -- '--draft'; then
  FIRST_READINESS="$(bash scripts/pr-readiness.sh remote "$PR_NUMBER" --allow-draft)"
else
  FIRST_READINESS="$(bash scripts/pr-readiness.sh remote "$PR_NUMBER")"
fi
printf '%s\n' "$FIRST_READINESS"
```

Preserve the first-readiness snapshot in a hidden PR body marker so
conflict-at-instantiation can be measured later:

```text
<!-- arboretum:ship-tail initial_remote_readiness=<value> initial_remote_reason=<value> initial_head_sha=<sha> initial_base_sha=<sha> -->
```

### 9. Request reviewers

After the PR is open (and not left as `--draft`), request the configured
reviewers through the review seam — this replaces the older "is Copilot PR
review enabled?" convention with the declared `.arboretum.yml` `review:` block.

On `github`, run the remote readiness gate before requesting reviewers:

```bash
PR_NUMBER="${PR_ID:-$(gh pr view --json number --jq .number 2>/dev/null)}"
REMOTE_READINESS="$(bash scripts/pr-readiness.sh remote "$PR_NUMBER")"
printf '%s\n' "$REMOTE_READINESS"
case "$REMOTE_READINESS" in
  readiness=ready\ *) bash scripts/request-review.sh "$PR_NUMBER" ;;
  *) echo "Remote readiness is not ready; do not request reviewers yet." >&2; exit 1 ;;
esac
```

On `azure-devops`, do not run `scripts/pr-readiness.sh remote`; the helper
reports unsupported remote readiness for ADO in this slice. Instead, invoke the
review seam directly so `request-review.sh` can add configured human reviewers
and emit its AI-review stub:

```bash
PR_NUMBER="${PR_ID}"
bash scripts/request-review.sh "$PR_NUMBER"
```

(or invoke `Skill arboretum:request-review` for the same effect with surfaced
per-reviewer results). `request-review.sh` reads the `review:` block and fires
each enabled reviewer via its own mechanism: on `github`, Copilot on draft→ready
and Codex on its `@codex` comment; on `azure-devops`, the AI request is a stub
(no native bot) and human reviewers are added directly. If the PR was created
`--draft`, skip this step and request review when `/land` marks it ready.

If `--draft` is present, skip `request-review.sh` entirely in `/pr`.

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
