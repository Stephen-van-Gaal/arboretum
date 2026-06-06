---
name: handoff
owner: session-handoff
description: "Queue a tracker item as `next-up` so the next session boots oriented on it. Single canonical writer for the session-handoff label — /cleanup, /reflect, and explicit completion-mode callers delegate here. Use directly when leaving mid-session ('I'm wrapping up; #154 is next')."
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
argument-hint: "[<item-number>] [--dry-run] [--completed]"
layer: 0
---

# Handoff

Captures session-handoff state by applying the **`next-up`** label to a single tracker item. The label is exclusive: the writer ensures at most one open item carries it at any time. The `session-start.sh` hook surfaces whichever item carries `next-up` in the boot banner of every subsequent session.

This skill is the **canonical writer** for the next-up label. Session-end skills
that queue follow-up work collect the item number and delegate tracker state
changes here. They never call vendor-specific tracker CLIs directly. `/finish`
does not invoke `/handoff` pre-merge; post-merge handoff is owned by
`/cleanup` / `/reflect`.

## When to use

- End of a session where you'll come back later (manual: `/handoff 155`).
- Mid-session, when leaving for the day or stepping away from a long-running task.
- Auto-invoked at the end of `/cleanup` and `/reflect`, and by any explicit
  completion-mode caller that needs to queue `next-up`.

## Procedure

### Stage logging

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /handoff entered
fi
```

At exit (when the procedure completes), log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /handoff exited
fi
```


### Step 1: Verify prerequisites

The mechanism uses the repo's configured tracker backend. Load the roadmap helper library and hard-fail if the selected backend is unavailable:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
ROADMAP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export ROADMAP_BACKEND
roadmap_require_backend "$ROADMAP_BACKEND" || exit 1
```

If the configured backend is unavailable, surface the helper's diagnostic and exit. No file fallback exists by design: `next-up` is shared tracker state so it works across machines.

### Step 2: Resolve the target item

If `$ARGUMENTS` contains a number (or `#N`), use it as the target item. Strip the leading `#` if present.

Otherwise, prompt once:

> "Which item should be queued as next-up? (Item number, or 'cancel')"

Use `AskUserQuestion` with a free-text response. If the user says 'cancel' or gives an empty answer, exit silently — the handoff is **advisory**, never gated.

If the input contains `--dry-run`, set a `DRY_RUN=1` flag; in dry-run mode print what *would* happen but don't mutate tracker state.

### Step 2b: Determine mode — completion or pause

`/handoff` runs in one of two modes (design §4.2):

- **Completion mode** — the priority list below resolves to completion. Apply the label only — skip Steps 3b–3d and 5b.
- **Pause mode** — the priority list below resolves to pause. Run the full procedure.

Detect with:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
DIRTY=$(git status --porcelain)
```

Mode is determined by an **ordered priority list — evaluate top-down, first match wins**:

1. If `--completed` is in `$ARGUMENTS` → **completion mode**.
2. If `BRANCH` is `main` or `master` → **completion mode**.
3. If `DIRTY` is non-empty → **pause mode**.
4. If the branch's matched plan has unchecked `- [ ]` boxes → **pause mode**.
5. Otherwise → **completion mode**.

### Step 3: Validate the target

Fetch the item and check it's open with a non-empty body:

```bash
roadmap_tracker_issue_show "$N" --json number,title,body,state
```

- **State must be `OPEN`.** If closed, refuse: *"Item #N is closed; cannot queue a closed item as next-up."* and exit.
- **Body must be non-empty.** Strip whitespace and check. If empty:
  > "Item #N has no body — fresh sessions won't have context to start from. Add context now (paste a few lines into the item), or apply `next-up` anyway?"
  Allow override; the readiness check is advisory. If the user chooses to add context first, exit so they can edit the item manually, then re-run.

### Step 3b: Cross-check the target (pause mode)

Attempt to determine the item the current branch belongs to:

1. Check the design spec matched by the branch topic for a `related-issue:` frontmatter field.
2. If an open PR exists for the branch and the current backend exposes PR lookup, read its body and extract the item number from a closing-reference pattern. If no such pattern is found, or if PR lookup is unavailable, treat the branch item as undetermined — show no warning. Do not call `gh pr view` directly from `/handoff`; branch-to-item inference must be backend-aware or skipped.

If a branch item (`M`) is found and it differs from the target (`N`), **warn the human explicitly** (design §4.3, decision #14):

> "⚠ The note describes work on the `<branch>` branch (item #M), but you're queuing #N as next-up. The handoff comment will post to #N. Continue, or change the target?"

Use `AskUserQuestion` and wait for confirmation. If the user changes the target, update `N` and re-validate (Step 3). If the branch item cannot be determined, show no warning — this check is best-effort.

### Step 3c: Draft and human-edit the note (pause mode)

Draft a handoff note from this session's live context. Format (design §4.5):

- **First line:** `→ Next action: <one concrete directive>` — the single most important thing the next session should do first.
- **Body:** freeform prose covering why you stopped, gotchas to watch out for, and any open decisions the next session needs to make. Do **not** restate branch, plan, or current step — the `[Build cycle]` banner already derives those from the label and plan file.

Show the draft to the human via `AskUserQuestion`:

> "Here is the draft handoff note:
>
> ---
> <draft>
> ---
>
> Post as-is, edit (paste replacement text), or skip (no note)?"

- **Post as-is** — use the draft.
- **Edit** — the human supplies replacement text; use exactly what they provide.
- **Skip** — no note is posted. This is advisory and never blocks the label-apply step. When the user skips, `NOTE_FILE` remains unset; Step 5b is omitted entirely.

Only human-approved text proceeds. There is **no path** that posts an AI draft without this gate. When the user chooses **Post as-is** or **Edit**, create a temp file and write the approved text to it:

```bash
NOTE_FILE=$(mktemp)
# write approved text to "$NOTE_FILE"
```

When `DRY_RUN=1`: show the draft and the tracker comment operation that would be run, but do **not** write the file to disk — carry the draft text in memory for Step 5b's dry-run output.

### Step 3d: Enforce the working tree (pause mode)

If `$DIRTY` (computed in Step 2b) is non-empty, the handoff must not leave a silent dirty tree (decision #6, §4.4):

1. Show the human the full list of changed files:

   ```bash
   git status --short
   ```

2. Ask **one** confirmation via `AskUserQuestion`:

   > "Commit these N files into a `wip: handoff` commit and push `<branch>`? (A stash is not offered — it cannot cross machines.) [yes/no]"

3. **On confirmation:** run the script and capture the short SHA:

   ```bash
   SHA=$(bash "$PROJECT_DIR/scripts/handoff-commit-wip.sh" "$PROJECT_DIR")
   ```

   If the user posted or edited a note in Step 3c (`$NOTE_FILE` is set), append to it: `WIP commit <sha> pushed — amend/rebase before continuing.` If the user chose **Skip** in Step 3c (no `$NOTE_FILE`), omit this line — there is nothing to append to; the wip-commit still happens but its SHA is not recorded in a note.

4. **On decline:** abort the handoff with a clear message and exit:

   > "Handoff not completed — working tree left dirty. Run /handoff again when ready to commit or after cleaning the tree."

Never offer a stash as an alternative — a stash is machine-local and cannot survive a machine switch.

When `DRY_RUN=1`: print the list of files, the commit message that would be used (`wip: handoff <date>`), and the push target, but make no commits and no pushes.

### Step 4: Enforce label exclusivity

`next-up` is **globally exclusive**: at most one open item carries it at a time.
The cross-issue logic — list every open holder and remove the label from each
one that is not the target — lives in `roadmap_set_globally_exclusive_label`
(`scripts/roadmap/lib.sh`) and runs as part of Step 5's apply call, so there is
no separate clearing loop to run by hand here. The helper keeps the label
genuinely exclusive without relying on tracker-side enforcement.

### Step 5: Ensure the label exists, then apply

`roadmap_set_globally_exclusive_label "$N" next-up` clears every other open
holder, ensures the label exists (bare), and applies it to the target in a
single call. It honors `DRY_RUN=1` — printing the planned operations and
mutating nothing.

`/handoff` keeps its own rich, idempotent label creation as a pre-step so the
first-ever `next-up` in a fresh repo carries a friendly description and color;
the helper's ensure-exists is only a bare floor.

```bash
# Rich label metadata — idempotent; the helper's bare ensure-exists is the floor.
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "would ensure label 'next-up' exists (description/color)"
else
  roadmap_tracker_label_create next-up \
    --description "Queued for the next session — see /handoff (issue #155)" \
    --color "b083d7" 2>/dev/null || true
fi

# Clear other holders + ensure-exists + apply to the target (honors DRY_RUN).
roadmap_set_globally_exclusive_label "$N" next-up
```

When `DRY_RUN=1`, the guard above and the helper print what they would do; no
tracker mutation runs.

### Step 5b: Post the handoff comment (pause mode)

Only run this step if the user posted or edited a note in Step 3c (`$NOTE_FILE` is set). If the user chose **Skip**, omit this step entirely — no comment is posted.

When `$NOTE_FILE` is set, run the post script with the temp note file from Step 3c, then set the session marker:

```bash
bash "$PROJECT_DIR/scripts/post-handoff-comment.sh" "$N" "$BRANCH" "$NOTE_FILE" "$PROJECT_DIR"
touch "$PROJECT_DIR/.arboretum/handoff-done"
```

The `handoff-done` marker tells the Stop and SessionEnd hooks a handoff was captured this session, so they stay silent. `session-start.sh` clears it at the next boot.

When `DRY_RUN=1`: print the tracker comment operation and the full comment body that would be posted (including the HTML marker and header the script prepends), but do not run the script, do not post the comment, and do not write the marker file.

### Step 5c: Post the pipeline-state `summary` log entry (D8)

After Step 5b (pause mode) — and also in completion mode immediately after Step 5 — post a journey-log comment carrying a one-sentence narrative of what this session accomplished. The action is `summary` (per WS9 D5 vocab — distinct from the `entered`/`exited` lifecycle that the `/handoff` skill itself logs).

The summary text is:
- **Pause mode:** the first non-blank line of `$NOTE_FILE` content (after the `→ Next action:` line). Trim to ≤ 200 chars, single line.
- **Completion mode:** a one-sentence narrative the agent writes from session context (no user approval needed — single sentence, easy to overwrite next session).

Invocation:

```bash
bash "$PROJECT_DIR/scripts/log-stage.sh" "$N" /handoff summary \
  "completion-mode=$([ "$COMPLETED" = "1" ] && echo true || echo false)" \
  "queued-next-up=$N" \
  "summary=$SUMMARY_TEXT"
```

If `DRY_RUN=1`: print the `log-stage.sh` command and the rendered log line, do not invoke the script.

**Why this matters:** WS9 D7's boot banner reads the most-recent `summary` log entry to answer "what did the last session accomplish?". Without this step, the banner's "Last session" line falls back to whatever last `summary` log entry exists (potentially weeks stale or missing).

### Step 6: Refresh the local cache

So the next session boot picks up the change immediately:

```bash
# Re-resolve from the active worktree in case this step runs independently.
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
bash "$PROJECT_DIR/scripts/refresh-next-cache.sh" "$PROJECT_DIR"
```

### Step 7: Confirm

One line:

- **Completion mode:** *"Queued #N (item title) as next-up. Surfaces in next session's banner."*
- **Pause mode:** *"Queued #N (item title) as next-up and posted the session-handoff note. Surfaces in the next session's banner."*

For example: *"Queued #155 (Session handoff…) as next-up and posted the session-handoff note."*

## Important

- **Single canonical writer.** `/cleanup`, `/reflect`, and explicit completion-mode callers invoke this skill rather than calling tracker CLIs themselves. If you're editing one of those skills and find yourself reaching for a vendor-specific issue command, stop and delegate here.
- **Advisory, not a gate.** Skip silently on user decline. Never block a parent skill on a missing handoff.
- **Hard fail on missing prerequisites.** Decision #6 in the design spec still applies: when the configured tracker is unavailable, surface install/auth instructions explicitly. Don't silently degrade.
- **Exclusivity is enforced by the writer.** Tracker backends do not enforce `next-up` uniqueness; this skill does. Each apply pass strips `next-up` from any other open item.
- **Not a backlog.** `next-up` is *handoff* — exactly one item. Strategic items go to ROADMAP.md (#152); tactical items remain in the full item list.
- **Dry-run.** `/handoff 155 --dry-run` prints the tracker calls, the drafted note, the files that would be `wip:`-committed, the commit message, and the push target — and mutates nothing. No commit, no push, no comment, no label, no marker file.
- **No stash, ever.** The only outcomes for a dirty tree in pause mode are: commit+push (on confirmation) or abort (on decline). A stash is never offered because it is machine-local and cannot survive a machine switch.
- **Completion mode bypasses the note and tree steps.** When invoked with `--completed` (by `/cleanup`, `/reflect`, or another explicit completion-mode caller), or when the tree is clean and the plan has no unchecked boxes, Steps 3b–3d and 5b are skipped entirely. No note is drafted, no tree enforcement runs.
- **Two writes per handoff.** `/handoff` writes both the human-readable handoff comment (Step 5b) AND a machine-parseable `summary` log entry (Step 5c). The two surfaces are intentional: humans read the handoff thread; the boot banner reads the `summary` log entry. Both must succeed for the next session's orientation to be complete.

$ARGUMENTS
