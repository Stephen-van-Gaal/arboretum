---
name: handoff
owner: session-start-cycle-state
description: "Queue a GitHub issue as `next-up` so the next session boots oriented on it. Single canonical writer for the session-handoff label — /finish, /cleanup, and /reflect delegate here. Use directly when leaving mid-session ('I'm wrapping up; #154 is next')."
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
argument-hint: "[<issue-number>] [--dry-run]"
layer: 0
---

# Handoff

Captures session-handoff state by applying the **`next-up`** label to a single GitHub issue. The label is exclusive: the writer ensures at most one open issue carries it at any time. The `session-start.sh` hook surfaces whichever issue carries `next-up` in the boot banner of every subsequent session.

This skill is the **canonical writer** for the next-up label. The session-end skills (`/finish`, `/cleanup`, `/reflect`) collect the issue number and delegate the GH state changes here. They never call `gh` directly.

## When to use

- End of a session where you'll come back later (manual: `/handoff 155`).
- Mid-session, when leaving for the day or stepping away from a long-running task.
- Auto-invoked at the end of `/finish`, `/cleanup`, and `/reflect`.

## Procedure

### Step 1: Verify prerequisites

The mechanism is GitHub-native. If `gh` is missing or unauthenticated, hard-fail with install/auth instructions:

```bash
if ! command -v gh >/dev/null 2>&1; then
  echo "/handoff requires the gh CLI."
  echo "  → Install: https://cli.github.com/"
  echo "  → Then: gh auth login"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "/handoff requires gh to be authenticated."
  echo "  → Run: gh auth login"
  exit 1
fi
```

If the project has no configured GitHub remote (none of the entries in `git remote` resolve to a GitHub URL), tell the user that the handoff feature requires GitHub and exit. Do not assume the remote is named `origin` — repos using `upstream`-style workflows are valid here, and `gh` itself decides whether the repo is readable. No file fallback exists by design.

### Step 2: Resolve the target issue

If `$ARGUMENTS` contains a number (or `#N`), use it as the target issue. Strip the leading `#` if present.

Otherwise, prompt once:

> "Which issue should be queued as next-up? (Issue number, or 'cancel')"

Use `AskUserQuestion` with a free-text response. If the user says 'cancel' or gives an empty answer, exit silently — the handoff is **advisory**, never gated.

If the input contains `--dry-run`, set a `DRY_RUN=1` flag; in dry-run mode print what *would* happen but don't mutate GH state.

### Step 3: Validate the target

Fetch the issue and check it's open with a non-empty body:

```bash
gh issue view "$N" --json number,title,body,state
```

- **State must be `OPEN`.** If closed, refuse: *"Issue #N is closed; cannot queue a closed issue as next-up."* and exit.
- **Body must be non-empty.** Strip whitespace and check. If empty:
  > "Issue #N has no body — fresh sessions won't have context to start from. Add context now (paste a few lines into the issue), or apply `next-up` anyway?"
  Allow override; the readiness check is advisory. If the user chooses to add context first, exit so they can edit the issue manually, then re-run.

### Step 4: Enforce label exclusivity

List all open issues currently carrying `next-up`:

```bash
gh issue list --label next-up --state open --json number --jq '.[].number'
```

For each number that is **not** the target, remove the label:

```bash
gh issue edit "$other" --remove-label next-up
```

This keeps the label genuinely exclusive without relying on GitHub-side enforcement (which doesn't exist for label uniqueness).

### Step 5: Ensure the label exists, then apply

```bash
# Create the label if missing. The exit code from `label create` is
# non-zero when it already exists; ignore that case.
gh label create next-up \
  --description "Queued for the next session — see /handoff (issue #155)" \
  --color "b083d7" 2>/dev/null || true

gh issue edit "$N" --add-label next-up
```

If `DRY_RUN=1`, print these commands instead of running them.

### Step 6: Refresh the local cache

So the next session boot picks up the change immediately:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
bash "$PROJECT_DIR/scripts/refresh-next-cache.sh" "$PROJECT_DIR"
```

### Step 7: Confirm

One line:

> "Queued #N as next-up. Surfaces in next session's banner."

Include the issue title for confirmation, e.g. *"Queued #155 (Session handoff…) as next-up."*

## Important

- **Single canonical writer.** `/finish`, `/cleanup`, and `/reflect` invoke this skill rather than calling `gh` themselves. If you're editing one of those skills and find yourself reaching for `gh issue edit`, stop and delegate here.
- **Advisory, not a gate.** Skip silently on user decline. Never block a parent skill on a missing handoff.
- **Hard fail on missing prerequisites.** Decision #6 in the design spec: when GitHub is unreachable but the project has a GH remote, surface install/auth instructions explicitly. Don't silently degrade.
- **Exclusivity is enforced by the writer.** GitHub doesn't enforce label uniqueness; this skill does. Each apply pass strips `next-up` from any other open issue.
- **Not a backlog.** `next-up` is *handoff* — exactly one issue. Strategic items go to ROADMAP.md (#152); tactical items remain in the full issue list.
- **Dry-run.** `/handoff 155 --dry-run` prints the GH calls it would make without executing. Useful for reviewing what's about to change.

$ARGUMENTS
