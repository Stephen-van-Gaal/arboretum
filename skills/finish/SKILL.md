---
name: finish
owner: git-workflow-tooling
description: Complete implementation work — verify, reconcile spec status to active via /consolidate if needed, and create a pull request. Use when implementation is done and you're ready to ship.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Grep, Glob, AskUserQuestion
layer: 0
---

# Finish

Guides the transition from "code is done" to "PR is created." Orchestrates verification, spec promotion, and PR creation in the right order.

## When to use

- Implementation is complete
- User says "I think we're done", "create a PR", "let's wrap up"
- After the implement → commit loop is finished

## Procedure

### Step 0: Read the pipeline.workflow flag from the project root

Before any other step, resolve the active worktree root:

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
```

Then validate the active named pipeline from that root:

```bash
PIPELINE="$(cd "$PROJECT_DIR" && bash "$PROJECT_DIR/scripts/read-pipeline-flag.sh")"
```

Also read the configured repo backend from the same root so the ship tail can use
the correct PR provider:

```bash
source "$PROJECT_DIR/scripts/roadmap/lib.sh"
SHIP_BACKEND="$(roadmap_backend "$PROJECT_DIR")"
export SHIP_BACKEND
```

The reader must succeed before the ship tail continues. The current
general-release pipeline follows the sequence below; the B4 review dispatch
(Step 5) is mandatory.

### Step 1: Verify implementation state

**Routing on `/build`'s exit-status (S3-8).** Before any other verification, read the most recent `/build exited` journey-log entry on the active issue and route on its `exit-status:` value. Until `scripts/get-latest-stage-log.sh` ships (WS9 follow-up), this is a descriptive routing — the operator confirms which path `/build` exited on:

When `exit-status: success` is the most recent `/build exited` value, continue the ship tail below (verify → consolidate → review dispatch (B4) → ship → PR).

When `exit-status: escape-hatch` is the most recent `/build exited` value, return to `/design` with the design spec as the in-flight authority. Halt — do not invoke `/pr` or any later stage. The escape-hatch outcome means the build surfaced a design decision that requires returning to `/design`.

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /finish entered
fi
```

Seed the pipeline-context ledger so the pre-merge ship-tail stages
(`/consolidate`, `/pr`) share the REGISTER spec-index for this HEAD instead of
each re-resolving it. (`/cleanup` and `/reflect` run post-merge, where the
advanced HEAD makes the SHA-keyed cache cold, so they are not wired in slice 1 —
design D2.) Best-effort — a failure never blocks `/finish`; the cache is purely
additive and self-invalidates on the next push (see
`docs/specs/pipeline-context-ledger.spec.md`):

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/refresh-pipeline-context.sh "$ISSUE" 2>/dev/null || true
fi
```

Check the current state:

```bash
git status --short
source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
git log "$(workspace_base_ref)"..HEAD --oneline
```

Report:
- **Uncommitted changes:** If any, offer a `stage named files + commit checkpoint` before pausing.
- **Commits on branch:** List them so the user can confirm the work is complete
- **Current branch:** Confirm it's a feature branch

If there are uncommitted changes, the checkpoint is:

1. Show `git status --short`.
2. Ask which exact files to stage.
3. Run `git add -- <file> [<file>...]` with only those named files.
4. Ask for or confirm the commit message, referencing the active issue when available.
5. Run `git commit --only -m "<message>" -- <file> [<file>...]` so pre-existing staged entries are not swept into the checkpoint commit.
6. Re-run `git status --short`; continue only when clean.

If the operator declines the checkpoint, wait for them to resolve the dirty tree before proceeding.

### Step 2: Identify affected specs

If `docs/REGISTER.md` exists:

1. Get all changed files on this branch:
   ```bash
   source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
   BASE="$(workspace_base_ref)"
   git diff "$BASE"...HEAD --name-only
   ```

2. Read the register's Spec Index with a bounded section read — it carries both the file→spec mapping and each spec's status, so no per-spec read is needed. Prefer the pipeline-context ledger (seeded above, keyed on this HEAD); fall back to the live section read on a miss:
   ```bash
   bash scripts/read-pipeline-context.sh spec_index 2>/dev/null \
     || bash scripts/read-doc-section.sh docs/REGISTER.md "Spec Index"
   ```
   The Spec Index table (`| Spec | Status | Owner | Owns (files/directories) |`) maps changed files to owning specs via the `Owns` column and gives each spec's state via the `Status` column. If the `Spec Index` heading is missing (malformed register), fall back to a whole-file read of `docs/REGISTER.md`.

Present:
```
## Specs affected by this branch

| Spec | Current Status | Action needed |
|------|---------------|---------------|
| <name> | draft | Run `/consolidate` to reconcile to `active` |
| <name> | stale | Run `/consolidate` to reconcile drift |
| <name> | active | OK — no action needed |
```

If any specs are still `draft` or `stale`, flag this — they should be at `active` before creating a PR. `/consolidate` reconciles `draft → active` (or `stale → active`).

### Step 3: Run health check

If `scripts/health-check.sh` exists:

```bash
bash scripts/health-check.sh "$(git rev-parse --show-toplevel)" 2>&1
```

Present results. If issues are found:
> "Health check found issues. Fix these before creating the PR? Or proceed anyway?"

### Step 4: Reconcile specs to `active` via `/consolidate`

For each spec affected by this branch, ensure its status is `active` (matches current code). Under the simplified state machine, status flips happen automatically:

- `/consolidate` flips `draft` → `active` when reconciliation succeeds.
- `/health-check` flips `active` → `stale` when drift is detected.

**If any affected spec is at `draft` or `stale`**, automatically invoke `/consolidate` to reconcile. `/consolidate` will run its normal interactive flow (presenting reconciliation plans for approval, regenerating AUTO sections, harvesting decisions). Don't ask the user whether to run it — running `/consolidate` is the mechanism by which `/finish` honors its name.

If all affected specs are already at `active`, this step is a no-op (skip silently).

Skip this step entirely for documentation-only changes (no source files in the diff).

### Step 5: Review dispatch (B4)

The B4 review stage is a **registry-driven section dispatch** over replaceable,
fresh-context reviewers (`docs/specs/review-stage.spec.md`, instantiating
`docs/specs/section-dispatch.spec.md`). It is **mandatory**. Reviewers are declared in
`reviewers.yml` (the registry — a sibling to `.arboretum.yml review:`, which configures
the *post-PR* bots); add, swap, or disable a reviewer by editing one row — never this step.

1. Build the request and select reviewers deterministically:

   ```bash
   source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
   BASE="$(workspace_base_ref)"
   # Pipe the changed-file list (regenerated NOW, not carried from an earlier stage)
   # straight into the filter — no shared temp path that a concurrent session/worktree
   # could clobber between generation and read.
   git diff "$BASE"...HEAD --name-only \
     | bash scripts/review-registry-filter.sh reviewers.yml \
         --altitude finish --artifact diff --base "$BASE" --files-from -
   ```

   The filter emits one JSONL record per selected reviewer — `{id, type, invoke, gate,
   normalizer}` — in registry (dispatch) order, with `{base}` already shell-quoted in
   runtime `invoke`s. `altitude`/`artifact` are **data**: they change the fan-out *width*,
   not this mechanism.

1a. **Review-dispatch gate (#854).** Before fanning out, read the per-lane relevance
   verdicts and the gate config, and soft-gate the skippable lanes so a trivial change
   does not pay the full review cost:

   ```bash
   git diff "$BASE"...HEAD --name-only | bash scripts/review-dispatch.sh --verdicts --files-from -
   ```

   - Read `gate.enabled` / `gate.unattended` from `reviewers.yml` (defaults when the block
     is absent: `enabled: true`, `unattended: run-everything`).
   - **`gate.enabled` is false** → skip this gate entirely; dispatch the full selected set
     as today.
   - Otherwise compute **skip-candidates** = selected lanes whose verdict `relevant` is
     `false`. In practice this is `general-security` on a prose-only change; `ai-surface`/
     `correctness` are already absent from the selected set when irrelevant. `--verdicts`
     classifies only the three skill lanes — a selected **runtime** reviewer (e.g. `codex`)
     is never a skip-candidate (it reviews docs too); it runs by default but the human may
     still force-skip it below.
   - **No skip-candidate** → no question; dispatch the full selected set (item 2).
   - **Skip-candidate(s) present:**
     - **Human present** → present a single `AskUserQuestion`: list each selected reviewer
       with its verdict reason (skip-candidates flagged), and ask which to run
       (Skip all / Run all / pick). The human may force-run a skip-candidate or force-skip
       any selected reviewer. Dispatch only the confirmed run-set. If the human skips
       **every** selected reviewer → **short-circuit**: dispatch nothing, record
       "B4 skipped — prose-only change (confirmed)", and continue to the next ship-tail step.
     - **No human present** (Auto Mode / unattended / non-interactive) → **fail safe**:
       honor `gate.unattended`. `run-everything` (default) dispatches the full selected set,
       no skip, and never silently auto-answers the question. `honor-classifier` drops the
       skip-candidates.

2. Fan out over the selected reviewers in **one batch, one level only** (a reviewer never
   dispatches reviewers), dispatching each by its `type`:

   - **`type: skill`** — dispatch a **generic `general-purpose` subagent** (per
     `docs/specs/skill-and-agent-authoring.spec.md` § "Fresh-context driver dispatch") and
     instruct it to **invoke** the row's skill, passing a brief carrying `diff_scope`, the
     reviewer `id`, and (for `ai-surface`) the matched `surface`, the CLAUDE.md scrub
     invariant, and the risk categories. The default registry's skill rows are:
     - `ai-surface` → invoke `/ai-surface-review` — via the Skill tool as `arboretum:ai-surface-review` (homegrown injection + data-flow).
     - `general-security` → invoke `/security-review` (the built-in general backend).
     - `correctness` → invoke `/code-review` (the correctness backend).

     **Invariant:** the reviewer/skill name is *what the subagent invokes* — never pass it
     as `subagent_type`; the subagent type is always `general-purpose`. Arboretum skills
     resolve under their plugin-prefixed Skill name (e.g. `arboretum:ai-surface-review`);
     the bare name does not. The subagent returns only the manifest.

   - **`type: runtime`** — run the row's `invoke` command via Bash and pipe its stdout
     through the row's adapter (for `normalizer: codex`, `scripts/review-adapter-codex.sh`),
     which **scrubs control chars at the boundary** and maps the CLI output onto the shared
     manifest. No subagent — wrapping a JSON-emitting CLI in a Claude context would violate
     the deterministic / LLM-free principle.

3. Validate each returned manifest with `scripts/validate-review-manifest.sh`. A manifest
   that fails is **dropped with an explicit notice** — never merged silently.

4. **Merge:** reconcile the produced manifests into one `ReviewResult` with:

   ```bash
   bash scripts/merge-review-manifests.sh --degraded "<deferred-ids>" <manifest>...
   ```

   Merge is deterministic and LLM-free (dedupe by `(location, recommendation)`, max
   severity on collision, lane provenance). **Skip merge only when exactly one reviewer ran
   AND none deferred** — then relay that lone manifest directly. If *any* reviewer deferred
   or was dropped, run the merge even for a single surviving manifest, so the `ReviewResult`
   still carries `reviewers_degraded` (Step 5's degradation notice depends on it).

5. **Degradation:** a reviewer whose backend is unavailable emits
   "&lt;id&gt; deferred to /land reviewers (Copilot/Codex)" — never a silent skip — and its
   id is passed to `--degraded` so the `ReviewResult` names who deferred.

6. A Critical finding is surfaced for the user to act on (no auto-halt this slice).

### Step 5.4: Template taxonomy advisory gate

If `scripts/validate-template-taxonomy.sh` exists, inspect changed paths against
the default branch:

```bash
source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
BASE="$(workspace_base_ref)"
CHANGED=$(git diff "$BASE"...HEAD --name-only)
```

Run `bash scripts/validate-template-taxonomy.sh` only when at least one changed
path matches:

- `docs/templates/document-shapes.yaml`
- `docs/templates/*.md`
- `docs/definitions/document-section-schema.md`

If the validator exits `0`, present its summary and continue. Warnings and
`lifecycle-required` findings are review items, not blockers. If it exits `1`,
pause the ship tail and ask whether to fix the hard alignment failure before PR
creation or explicitly proceed with the failure called out in PR context. If it
exits `2`, stop because the validation result is unknown.

### Step 5.5: Pre-PR local CI gate

Before local CI, check the local-candidate against the current base. This is the
cheap mergeability gate that prevents running expensive tests on a branch that
already cannot proceed:

```bash
source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
BASE_REF="$(workspace_base_ref --fetch)"   # ship-tail pre-PR: --fetch for a fresh base (helper does the bounded fetch)
LOCAL_READINESS="$(bash scripts/pr-readiness.sh local "$BASE_REF")"
printf '%s\n' "$LOCAL_READINESS"
case "$LOCAL_READINESS" in
  readiness=ready\ *) ;;
  readiness=blocked\ *|readiness=unknown\ *)
    echo "Local readiness failed before local CI. Repair or escalate before continuing." >&2
    exit 1
    ;;
esac
```

Determine the local check command from the project's declared testing shape. If
the testing-shape spec is present but invalid, stop; do not fall back to
`scripts/ci-checks.sh`. If the spec is absent, `/finish` keeps its narrow
pre-PR behaviour and skips this local gate instead of adding package/Makefile
discovery:

```bash
TEST_SPEC="docs/specs/test-infrastructure.spec.md"
RTC_ERR=$(mktemp)
if CFG=$(bash scripts/read-test-config.sh "$TEST_SPEC" 2>"$RTC_ERR"); then
  TEST_CMD=$(printf '%s\n' "$CFG" | grep -m1 '^default-command=' | cut -d= -f2-)
else
  if [ -f "$TEST_SPEC" ]; then
    echo "ERROR: $TEST_SPEC is present but invalid; do not fall back to scripts/ci-checks.sh." >&2
    cat "$RTC_ERR" >&2
    rm -f "$RTC_ERR"
    exit 1
  fi
  TEST_CMD=""
fi
rm -f "$RTC_ERR"

if [ -n "$TEST_CMD" ]; then
  eval "$TEST_CMD"
else
  echo "no declared default-command — skipping pre-PR gate"
fi
```

Run **only** `default-command` — never the `opt-in-commands` tiers. If it exits
non-zero, present the failures and fix them before proceeding — the PR should be
green from its first push.

This is the **final pre-PR gate**, so run it in the default (repair-enabled)
mode — do **not** set `ARBORETUM_CI_READONLY=1` here. By this point the branch
has diverged from main, so a coverage-manifest repair leaves a reviewable,
committable diff. The read-only mode (`ARBORETUM_CI_READONLY=1`) is for
*intermediate* green-checks on uncommitted work (see `/design`), not this gate
(#688).

After local CI passes, run the same readiness check again. If the branch moved
or the test run generated unexpected files, stop before invoking `/pr`:

```bash
source "$(git rev-parse --show-toplevel)/scripts/workspace-context.sh"
BASE_REF="$(workspace_base_ref --fetch)"
LOCAL_READINESS="$(bash scripts/pr-readiness.sh local "$BASE_REF")"
printf '%s\n' "$LOCAL_READINESS"
case "$LOCAL_READINESS" in
  readiness=ready\ *) ;;
  readiness=blocked\ *|readiness=unknown\ *)
    echo "Local readiness failed after local CI. Repair or escalate before creating the PR." >&2
    exit 1
    ;;
esac
```

### Step 5.8: Tracker closure-intent audit

Before invoking `/pr`, resolve the active tracker issue using the same priority
order as `/pr`: `$ISSUE`, then the current branch slug's design spec
`related-issue:` frontmatter, then no issue. Present a concise audit:

```text
Tracker closure intent:
- Will close: #<issue> | none
- References only: #<issue-list> | none
- Provider verification: supported | unsupported | unknown
```

For `github`, provider verification is `supported` when exactly one closeable
issue will be rendered with a GitHub closing keyword in `/pr`'s `## Tracker`
section. For `azure-devops`, provider verification is `unknown` until
post-merge `/cleanup`: `/pr` will link the work item, but Arboretum must not
claim closure until the read-only linked-work-item state check runs.

If no tracker issue is resolved, warn clearly but continue when the user wants
a trackerless PR.

### Step 6: Create PR

Invoke the `/pr` skill to create the pull request through `$SHIP_BACKEND`. It handles:
- Health check summary
- Spec context
- Pushing the branch
- Creating the PR via `gh pr create` for `github`
- Creating the PR via `az repos pr create` for `azure-devops`

For the chained GitHub ship tail, invoke `/pr --draft` by default unless the
user explicitly requested a ready PR. The draft PR is the draft-candidate:
GitHub can compute mergeability, but reviewers are not requested until `/land`
confirms remote readiness.

Present the PR URL when done.

### Step 6.3: Hand off to `/land`

After the PR is created, invoke `/land <pr-number>` to drive it to merge-ready
through the same backend. For `github`, `/land` runs the existing CI/reviewer
poll loop. For `azure-devops`, `/land` uses Azure Repos state and policy checks
and hands off any unsupported reviewer-thread automation explicitly. `/land`
runs its own asynchronous loop where supported; `/finish` does not block on it.

### Step 7: Suggest next steps

After the PR is created:
> "PR created: <url>
>
> After it's approved and merged, run `/cleanup` to switch to main, pull, and delete this branch. The ship tail is `/cleanup` → `/reflect` → `/handoff`; `/reflect` Q5 is the canonical handoff invocation (queues `next-up` against an issue that is actually-open post-merge)."

At exit, if `$ISSUE` is set, log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /finish exited
fi
```

## Unified ship tail

The ship tail sequence is: verify → identify affected specs → health-check →
`/consolidate` → review dispatch (B4) → template taxonomy advisory gate →
local CI gate → backend-aware `/pr` → backend-aware `/land`.

The model-level differences that matter to `/finish` are upstream:
everything-else pre-build work produces an in-flight design spec, and `/design`
may have already committed approved durable intent/seam edits. Those choices
change what `/consolidate` reconciles in Step 4, not what `/finish`
orchestrates:

- Step 2's "specs affected by this branch" list will, for everything-else changes, always include the design spec at `docs/superpowers/specs/`; that spec drives `/consolidate`'s behaviour but is not itself a governed spec.
- Step 4's `/consolidate` invocation is the reconciler for generated/evidence sections and built-state updates. The "If any affected spec is at `draft` or `stale`" check still applies — `/consolidate` flips `draft → active` when reconciliation succeeds.
- Step 5's review dispatch is mandatory — select reviewers with `scripts/review-registry-filter.sh reviewers.yml` and fan out each selected reviewer (skill rows → `/ai-surface-review`, general-security, correctness; runtime rows → their adapter) rather than offering review optionally. Reviewers degrade to the `/land` reviewers when a backend is absent.

These notes explain the current release pipeline; the procedure steps above
remain authoritative.

## Important

- This skill orchestrates existing skills (`/consolidate`, the B4 review dispatch, `/pr`, `/land`). It doesn't duplicate their internals — it calls them in the right order.
- **`/handoff` is no longer invoked here** (WS1 D8). The pre-merge handoff in the prior Step 6.5 queued `next-up` against the issue the PR was about to close — a race that resolved incoherently. Handoff now fires post-merge from `/reflect` Q5, which is the single canonical handoff invocation in the ship tail.
- **`/land` is merge-readiness-only.** It does not close tracker items; post-merge tracker verification and any safe fallback close belong to `/cleanup`.
- Steps are sequential and each depends on the previous one. Don't skip ahead.
- If the user wants to create a PR without reconciling spec status via `/consolidate` or running health checks, let them — this is guidance, not a gate. But note what was skipped.
- For documentation-only branches (no source code changes), there is typically no spec-status reconciliation needed; the B4 review dispatch still runs — `ai-surface` fires when an AI-facing instruction file changed, `correctness` is skipped (the diff has no code), and `general-security` is a skip-candidate on a *prose-only* change: the gate (Step 5 item 1a) asks the human whether to run it or skip B4, while config changes (e.g. `*.yml`/`*.json`) keep it. With no human present it still runs (fail-safe).

$ARGUMENTS
