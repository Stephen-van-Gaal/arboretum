---
name: request-review
owner: git-workflow-tooling
description: Request (or re-request) the reviewers declared in .arboretum.yml's review: block, each via its configured mechanism, through the project's repo backend. Thin orchestrator over request-review.sh; standalone-invocable to re-prompt review on an existing PR.
disable-model-invocation: false
allowed-tools: Bash, Read, AskUserQuestion
argument-hint: "[<pr-number>] [--reviewer <name>] [--re-request]"
layer: 0
---

# Request Review

Request — or re-request — the reviewers an arboretum project has declared in
`.arboretum.yml`'s `review:` block, each through the mechanism that reviewer
actually responds to (Copilot fires on draft→ready; Codex on an `@codex`
comment; ADO has no native bot, so its AI request is a stub and human reviewers
are added directly). The mechanics live in `scripts/request-review.sh`; this
skill is the thin judgment layer that decides *which* reviewers to ask and
surfaces the result.

## When to use

- Called by `/pr` after a PR is opened (initial request).
- Called by `/land` in the fix sub-loop (re-request — M-C wires the
  `re_review_condition` policy that decides *whether* to re-request).
- Standalone to re-prompt review on an existing PR: `/request-review <pr>`.

## Procedure

### 1. Resolve the PR

`$ARGUMENTS` may lead with flags (`--reviewer <name>`, `--re-request`) and omit
the PR. Take the PR only when the first token is numeric; otherwise resolve from
the branch:

```bash
FIRST="${ARGUMENTS%% *}"                 # first whitespace-delimited token
case "$FIRST" in ''|*[!0-9]*) PR="" ;; *) PR="$FIRST" ;; esac
[ -n "$PR" ] || PR="$(gh pr view --json number --jq .number 2>/dev/null)"
[ -n "$PR" ] || { echo "No PR number given and none found for the current branch."; exit 1; }
```

### 2. Show what's configured

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
( cd "$PROJECT_DIR" && bash scripts/read-review-config.sh )
```

This prints the enabled reviewers and their per-reviewer `request`/`re_request`
mechanism and `cadence`. If the block is absent, the reader warns and no
reviewers are requested — surface that to the user (the fix is to add a
`review:` block, not to hand-tag reviewers).

### 3. Request the reviewers

For the initial request (from `/pr` or standalone):

```bash
bash scripts/request-review.sh "$PR"
```

To re-request (from `/land`'s fix loop, or standalone after a fix push), pass
`--re-request`; scope to one reviewer with `--reviewer <name>`:

```bash
bash scripts/request-review.sh "$PR" --re-request --reviewer codex
```

Preview without touching the network by exporting `REVIEW_DRY_RUN=1` first — the
script prints the intended per-reviewer action instead of executing it.

### 4. Surface the result

Report each `requested:`/`re-requested:` line the script emitted. Add the
cadence caveat where it matters: a reviewer whose `cadence` is `auto-flaky`
(e.g. Copilot) may not re-review on a later push even after a re-request — the
documented levers are flip-to-ready or the GitHub UI "re-request" button. A
`comment-trigger` reviewer (e.g. Codex) only reviews when its `@`-comment is
posted, which the script does.

## Scope notes

- **M-A (this skill's current scope):** request *all* enabled reviewers. The
  complexity-gated "should we request feedback at all?" decision and the
  `--no-review`/`--request-review` overrides land in `/pr` (M-B). The
  `re_review_condition` policy that decides *whether* `/land` re-requests lands
  in `/land` (M-C).
- The skill never merges, never resolves threads, and never collects feedback —
  collection is `scripts/collect-review.sh`; thread resolution is
  `arboretum:receive-review`.
