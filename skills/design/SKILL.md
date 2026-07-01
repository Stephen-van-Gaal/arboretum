---
name: design
owner: workflow-unification
scope: plugin-only
description: Wrapper skill that orchestrates the design phase — produces the in-flight design spec, folds in planning, and exits to `/build` after human review. Use at the start of planned work.
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
argument-hint: "[path/to/design-spec.md | change request text]"
layer: 0
---

# Design

Orchestrates the transition from idea to an implementable design package. This
is a wrapper that coordinates external design skills with arboretum's
governance.

## When to use

- Starting planned work (user knows what they want to build)
- After `/start` routes to the planned path
- When the user says "let's design this" or "let's spec this out"

## Procedure

### Step 0: Read the pipeline.workflow flag

Before any design routing, validate the active named pipeline:

```bash
PIPELINE=$(bash scripts/read-pipeline-flag.sh)
```

The reader must succeed before writing design artifacts. Arboretum currently
supports one general-release pipeline: every everything-else change produces an
in-flight design spec, planning folds into this skill, approved durable
intent/seam edits may be made before `/build`, and `/finish`/`/consolidate`
reconciles generated/evidence sections from built state.

## Unified design phase

`$ARGUMENTS` arrives from `/start` in the form `Issue #<N>: <change request text>`.

Parse `$ARGUMENTS` for the issue number and the request text — the issue number
populates `related-issue` in the S2 frontmatter (`/build`'s strict gate
requires a positive integer). If `$ARGUMENTS` is
`Issue #pending: <request>`, prompt the user to create the tracker issue before
writing the design spec (use `roadmap_tracker_issue_create` per the project's
standard issue templates) and substitute the new issue number.

`$ARGUMENTS` carries change-request text plus an issue prefix, not a spec path.

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /design entered
fi
```

#### Worktree guard (create-if-absent, #716)

`/design` writes durable files (the design spec, the plan), so before that work
apply the worktrees-always **create-if-absent guard** — the idempotent safety net
for sessions that entered `/design` directly, skipping `/start`'s creation seam:

```bash
source scripts/workspace-context.sh
workspace_is_session_worktree; rc=$?
```

- `rc == 0` — already in a session worktree → **no-op** (the common case when
  `/start` already created it; this guard never double-creates).
- `rc == 1` — primary tree. **If on the default branch**, offer to isolate this
  work in a worktree (same 2-step mechanic as `/start` Step 3b: `git worktree add
  .claude/worktrees/feat-<issue>-<slug> -b feat/<issue>-<slug> origin/main` then
  `EnterWorktree --path`). **If already on a feature branch** (e.g. the user
  declined a worktree at `/start`), **no-op** — respect the existing branch.
- `rc == 2` — not a git tree → no-op.

This guard respects a decline by construction: a declined user is on a feature
branch, so the `rc == 1 && default-branch` condition is false.

### 1. Survey

Before any design work, read existing governed code that may be relevant to the topic:

1. List `docs/specs/` and read any spec whose name plausibly overlaps the request topic — don't infer from filenames alone.
2. Read `docs/ARCHITECTURE.md` via bounded discovery — `bash scripts/explore-doc.sh docs/ARCHITECTURE.md` to list headings, then `bash scripts/read-doc-section.sh docs/ARCHITECTURE.md "<relevant heading>"` for the section(s) relevant to the request area. Fall back to a whole-file read only when discovery is insufficient, recording the reason in the survey summary.
3. Read `docs/REGISTER.md` — identify the owning spec for any files the request mentions explicitly.

Survey is owned exclusively by this skill for everything-else work. `/start`
does the cheap routing pass; `/design` owns the contextual read of governed
specs, architecture, and register entries.

When a relevant governed spec, design spec, plan, or shipped template is
structured enough for bounded access, prefer discovery before whole-file reads:

```bash
bash scripts/explore-doc.sh <document>
bash scripts/read-doc-sections.sh <document> purpose behaviour
```

Choose semantic keys from the discovery output. If discovery is unavailable,
missing, or insufficient for the design question, fall back to
`scripts/read-doc-section.sh` for explicit headings, then to a whole-file read
with the reason recorded in the survey summary.

When the request or survey touches shared vocabulary, workflow terms, tracker
labels or states, document shapes, read-profile language, routing/design taxonomy,
release-intent language, or review-cadence language, read the definitions index
and concept catalog compact profiles:

```bash
bash scripts/read-doc-profile.sh docs/definitions/README.md compact
bash scripts/read-doc-profile.sh docs/definitions/concept-catalog.md compact
```

Treat the definitions index as the controlled-vocabulary inventory and the
concept catalog as naming/context authority. They point to owner specs and
canonical surfaces; they do not replace those owner specs for behaviour.

Read repo-relative owner or canonical paths from those profiles only when those
paths exist in the current checkout. In public/adopter checkouts, arboretum-dev
specs, design docs, plans, and dev release contracts may be absent; use the
public fallback surfaces named in the profiles (skills, workflows, templates,
contracts, helper scripts, and local config) and surface an
authority-unavailable warning before relying on any missing owner. If a profile
read fails, surface an authority warning and continue with the normal
governed-spec survey instead of claiming that profile was consulted.

### 2. Triage change kind to Branch 1 mode

Branch 1 has four modes; each converges on a design spec but the dialogue shape differs. Ask the user (via `AskUserQuestion`) which mode fits, with the default inferred from the request type:

| Request type | Branch 1 mode | Provider skill |
|---|---|---|
| New or changed behaviour | **brainstorm** | `superpowers:brainstorming` |
| Bug fix | **investigate** | `superpowers:systematic-debugging` |
| Refactor (behaviour preserved) | **coverage-baseline** | (no external skill — establish/verify test coverage first; no behaviour brainstorm) |
| Well-defined or docs-only | **none** | (no dialogue — author a thin design spec directly) |

**Precedence on ambiguity:** present the inferred default and offer the other three as alternatives. If the user picks **none** for a change that isn't trivially well-defined, push back once and confirm — "none" skips the design dialogue entirely; misusing it for a non-trivial change loses the value of Branch 1.

### 3. Dispatch Branch 1

Invoke the mode's provider skill (if any) with a brief that includes:

- The user's original request (from `$ARGUMENTS`)
- The SURVEY output (relevant governed specs, architecture excerpts)
- Naming convention: design spec lands at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- Template: for modes where this skill authors the spec directly (investigate, coverage-baseline, none), use `docs/templates/spec.md` as the structural skeleton so `/consolidate` at `/finish` can harvest from it correctly

Before writing the design spec, apply the **customer/operator experience check**:
when the change affects workflow steps, ship-tail behaviour, error or warning states,
user decisions or confirmations, or trust boundaries where Arboretum
might otherwise overclaim, include a short `## Customer Experience` section (or
equivalent clearly named section) in the design output. The section should cover
the normal path, the failure or unknown path, and user decision points: what the
human sees, what they are asked to decide, what confidence Arboretum is claiming,
and what happens when Arboretum cannot know. Purely internal refactors with no
user-visible workflow effect may omit the section.

For **brainstorm** mode, the provider's output is the design spec. For **investigate** mode, the provider's output is a structured root-cause analysis; transcribe it into the design spec template. For **coverage-baseline** mode, run the project's declared default test command (`default-command` from `docs/specs/test-infrastructure.spec.md` via `bash scripts/read-test-config.sh`; if the spec file is present but the reader fails, fail the coverage-baseline gate and surface its stderr diagnostic; if the spec file is absent, fall back to native product-test discovery via `package.json`/`Makefile`/`pytest.ini`; never run the `opt-in-commands` tiers), identify coverage gaps in the refactor's blast radius, and document them in the design spec's Behaviour section as "tests to add before the refactor begins". For **none** mode, author the design spec directly from the request — Purpose + Behaviour + a single "decision: change is trivially well-defined, no Branch 1 dialogue needed" entry.

All four modes produce a design spec at the conventional path. The spec is
mandatory for everything-else work; never skip it.

### 4. Plan fold-in

**Shaping-doc guard (skip plan fold-in).** If this session produced an
epic/shaping design doc (`kind: shaping` — no build of its own; its children
build individually, never this doc), **skip plan fold-in entirely**: do not
invoke `superpowers:writing-plans`, and **omit the build-targeted fields**
(only `related-issue` + `kind: shaping` are required — see the shaping schema in
Step 6), then proceed directly to `design-package` / exit. A plan for a doc
that will never build is wasted work, and `/build` refuses such a doc anyway
(read-s2 exit 3). The unconditional `writing-plans` invocation below applies only
to `kind: buildable` (the default) sessions.

Planning is part of `/design`, not a separate workflow stage. After the design
spec is written, invoke `superpowers:writing-plans` with a brief that includes:

- The design spec path (the writing-plans skill will read it)
- Project plan convention: `docs/plans/YYYY-MM-DD-<topic>.md` (NOT the writing-plans default `docs/superpowers/plans/`)
- Test taxonomy from `CLAUDE.md ## Testing`
- Workflow stage: plans end at `/finish`; no "promote spec to active" step (status flips automatically at `/consolidate`)
- **Build-time governance prerequisites:** if the plan will create any
  `scripts/*.sh` (excluding `_`-prefixed components), the brief must instruct
  `writing-plans` to open the plan with a **Task 0: governance scaffolding** that
  creates a contract stub per new script, seeds a draft owner-spec for each new
  `# owner:` topic lacking a `docs/specs/<topic>.spec.md`, and regenerates
  `docs/contracts/_coverage.md` — *before* any task that adds a script. The build
  gate (`scripts/ci-checks.sh`) enforces contract coverage and owner→spec
  existence the instant a script appears, so this work must be budgeted up front
  rather than improvised mid-build; it mirrors the seam scaffolding
  `design-package` Step 6 emits into the Durable Document Change Set.
  `writing-plans` is an **external superpowers skill** Arboretum cannot edit, so
  this rule lives in the brief `/design` hands it (and in `/design`'s own plan
  authoring when superpowers is absent), not in `writing-plans` itself.

After writing-plans returns, verify the plan landed at `docs/plans/`, not `docs/superpowers/plans/`. If it landed in the wrong place, move it with `git mv` (preserves history) and update the `plan:` field in the design spec frontmatter to match the new path — `/build` reads that field, and a stale `plan:` pointer causes a "plan path not found" error.

### 5. Design package: human overview and durable-document change set

After the AI-facing session document and plan exist, invoke or follow
`design-package` against the session document. The package is the human review
packet for the session. It must include the overview and Durable Document
Change Set with exact file paths, operations, high-level changes, reasons, and
phase classification.

The `design-package` skill must validate buildability after the `plan:` field is final,
discover the document shape, retrieve available sections with both
cataloged shape keys and discovered heading keys, classify the source as
`strict-design-session`, `partial-design-session`,
`custom-s2-design-session`, `plan`, or `unknown`, and fail closed on `unknown`.

Pre-build durable edits are allowed only for intent authority and seam
authority. Intent authority includes purpose, problem, scope, requirements,
customer/operator experience, architecture boundaries, naming, splitting/lumping,
trade-offs, and Behaviour/Boundaries-style human prose. Seam authority includes
definitions and contracts implementation must obey.

Generated/evidence authority is not finalized before build unless the evidence
already exists. Ownership, Tests, Design record, decision harvest, register,
and contract coverage remain `/finish`/`/consolidate` work.

The package review must preserve the intent authority, seam authority, and
generated/evidence boundaries in the Durable Document Change Set.

Present the overview, plan, and durable-doc diff to the human. If approved,
commit and push the approved durable intent/seam edits before `/build`. Do not
log `/design exited` or hand off to `/build` until the human has approved the
overview, plan, and durable-doc diff.

Sequence summary:

- `/start` -> `/design` is the issue/request intake seam.
- `design` writes the session document, folds in the plan (skipped for
  `kind: shaping` sessions), then invokes `design-package` to produce the human
  review packet and durable-doc diff.
- `/design` -> `/build` remains the strict S2 contract seam.
- `/build` refuses to self-heal invalid S2 input and returns to `/design` on
  design contradictions.

### 6. Exit

For a `kind: buildable` session, both the design spec and the plan now exist and
the exit hands off to `/build`. For a `kind: shaping` session, only the design
spec exists (build-targeted fields omitted) and the exit is **terminal at human
review** — there is no `/build` handoff, because its children are filed and built
as separate issues, never this doc. **Before exiting**, run the S2 producer
self-check:

```bash
bash scripts/validate-design-spec.sh <design-spec-path>
```

If the validator exits non-zero, the spec is malformed against the S2 contract — fix the named field(s) and re-run before handing off. Per the S2 contract's D4 single-source-of-truth property, this is the same validator `/build` invokes at its entry step; passing it here guarantees `/build` will accept the spec.

Before exiting (to `/build` for a buildable session, or terminally for a shaping
session), stop for human review of the design package.
Everything-else work must not proceed into implementation until the user
approves the goals, requirements, done criteria, design decisions, test
approach, and plan. The only no-review exception is work that entered the
low-friction path from verified `agent-ready` and therefore skipped `/design`.
Do not log `/design exited` or hand off to `/build` until that approval has
happened; while waiting for review, the stage is still in `/design`.

#### 6a. Grant gate (buildable sessions only — the design→build autonomy authorization, #917)

For a **buildable** session, the human review you just completed is also the
**grant gate**: the single synchronous authorization of *how far this run
proceeds unattended* (#915 D1/D8). It does not move the review-before-build
pause — it extends it with one tier choice. (Skip this for `kind: shaping`
sessions: a shaping doc ships no run to authorize.)

Read the project's default tier, then ask the human with the **one common
closed-option affordance** (D8 — an `AskUserQuestion`):

Fail closed — if the config reader errors (invalid `.arboretum.yml`, removed
trigger floor), the grant gate must **not** proceed with an undefined
recommendation:

```bash
if ! AUTONOMY_CFG="$(bash scripts/read-autonomy-config.sh)"; then
  echo "Grant gate: autonomy config is invalid — fix .arboretum.yml before setting a grant." >&2
  # Stop here; do not present the gate.
fi
DEFAULT_GRANT=$(printf '%s\n' "$AUTONOMY_CFG" | grep -m1 '^default_grant=' | cut -d= -f2)
[ -n "$DEFAULT_GRANT" ] || { echo "Grant gate: default_grant unreadable — stop." >&2; }
```

Present exactly these options, with the `$DEFAULT_GRANT` tier pre-selected and
labelled `(Recommended)`:

- **design-only** — *(today's default)* no autonomous reach; the human drives
  `/build → … → merge`. Sets no label.
- **autonomy:pause-at-land** — autonomous `/build → /finish → /pr`; human drives `/land`.
- **autonomy:pause-at-merge** — also runs the `/land` loop unattended; human makes the merge call.
- **autonomy:auto-merge** — full reach; merge on clean convergence (eligibility only — still gated by `auto_merge_enabled`).

**The human grants; Codex advises but never grants (D1).** If a design-package
Codex review recommended a tier, surface it as advice in the prompt — it is an
input, never the decision. Never auto-select above `$DEFAULT_GRANT` on Codex's
say-so.

Record the chosen tier `$GRANT` (one of `pause-at-land | pause-at-merge |
auto-merge | design-only`). For a real tier, set the exclusive label (the
authoritative carrier, read downstream by `scripts/read-autonomy-grant.sh`). For
`design-only`, **actively clear any existing `autonomy:*` label** — a prior run
(re-running `/design`, or downgrading a grant) may have left a stale tier that
`read-autonomy-grant.sh` would otherwise keep returning; absence-of-label is the
design-only carrier, so the label must be removed, not merely not-added:

```bash
( cd "$(git rev-parse --show-toplevel)" && source scripts/roadmap/lib.sh && \
  if [ "$GRANT" != "design-only" ]; then
    roadmap_set_prefix_exclusive_label "$ISSUE" autonomy "$GRANT"
  else
    # design-only: remove any stale autonomy:* label so the grant reads as design-only.
    stale=$(roadmap_tracker_issue_show "$ISSUE" --json labels --jq '.labels[].name' 2>/dev/null \
            | grep '^autonomy:' | paste -sd, - || true)
    [ -n "$stale" ] && roadmap_tracker_issue_update "$ISSUE" --remove-label "$stale"
  fi )
```

**Slice-1 scope (be honest, do not overclaim, #917).** This gate *records* the
grant; it does **not** yet make `/build` or any later stage act autonomously.
Trigger evaluation, autonomous `/land`, and the derived merge gate arrive in
#918–#921 — until then the run proceeds exactly as today regardless of the tier.
Say so at the gate rather than implying the run will now drive itself.

After approval (and, for buildable sessions, after recording the grant), if
`$ISSUE` is set, log `/design exited` — buildable sessions carry the grant on the
seam as a `grant=` entry (the pipeline-state journey log is the grant's audit
trail, #922); shaping sessions log it grant-free:

```bash
if [ -n "${ISSUE:-}" ]; then
  if [ "${GRANT:-}" != "" ]; then
    bash scripts/log-stage.sh "$ISSUE" /design exited "grant=$GRANT"
  else
    bash scripts/log-stage.sh "$ISSUE" /design exited
  fi
fi
```

For a `kind: shaping` session the exit is terminal here: there is no `/build`
handoff. Stop after the human approves the design package; the doc's children are
filed and built as separate issues. The buildable handoff below does not apply.

After approval (buildable sessions), hand off to `/build` with the design spec
path:

```
/build docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
```

`/build` reads the S2 frontmatter on the design spec and dispatches
accordingly. This skill is responsible for populating ALL five required fields
— `/build`'s gate is strict and rejects any missing field. Use this schema:

```yaml
related-issue: <N>
triage: everything-else          # agent-target | everything-else
implementation-mode: direct      # direct | executing-plans | subagent-driven-development
plan: docs/plans/YYYY-MM-DD-<topic>.md   # relative path | null
test-tiers:
  unit: yes                      # yes | n/a — <reason>
  contract: n/a — no shared definitions touched
  integration: yes
```

**Epic / shaping design docs** (a doc that stops after human review — its children
build individually, never this doc) instead carry the optional `kind: shaping`
marker and **omit the five build-targeted fields**; only `related-issue` is
required in frontmatter. `validate-design-spec.sh` accepts this, and `/build`
refuses such a doc (read-s2 exit 3). Use it for epic-level design docs so they
validate without masquerading as a buildable `/build` input (S2 contract v1.1,
#692):

```yaml
related-issue: <N>
kind: shaping
```

A `kind: shaping` doc must **also carry a non-empty `## Substrate Survey`
section** (S2 contract v1.3, S2-9, #934) — the substrate survey `design-package`
Step 6 performs. `validate-design-spec.sh` fails a shaping doc that omits it
(`S2-DRIFT … Substrate Survey`), so the survey is part of producing a valid
shaping doc, not optional.

(Auto-emitting `kind: shaping` from an epic/shaping `/design` session is not yet
automated — set it by hand for now.)

Do not auto-invoke `/build`. The user (or the calling skill) drives the next stage.

## Important

- This skill is the **conductor** for the design phase. It doesn't replace brainstorming — it ensures the output lands in the right place (governed specs, not just design docs).
- The critical value is the design spec path-aware exit: everything-else work
  leaves `/design` with an in-flight design spec and plan, then `/consolidate`
  creates or reconciles governed specs from built state during `/finish`.
- If the user wants to skip design dialogue because the change is truly
  well-defined, use Branch 1 mode `none` and author the thin design spec
  directly.
- If the work is still exploratory, route to the explore workflow before
  producing a design spec.
- **Intermediate green-checks must be read-only.** If you run
  `scripts/ci-checks.sh` as a sanity check during design — before the work is
  committed — invoke it as `ARBORETUM_CI_READONLY=1 bash scripts/ci-checks.sh`
  (or commit first). The default mode runs the repair-enabled preflight, which
  can write the working tree (coverage-manifest regen) you did not intend to
  mutate mid-design. Read-only mode reports drift without repairing it (#688).

$ARGUMENTS
