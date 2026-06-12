---
name: design
owner: workflow-unification
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
- `design` writes the session document, folds in the plan, then invokes
  `design-package` to produce the human review packet and durable-doc diff.
- `/design` -> `/build` remains the strict S2 contract seam.
- `/build` refuses to self-heal invalid S2 input and returns to `/design` on
  design contradictions.

### 6. Exit to `/build`

Both the design spec and the plan now exist. **Before exiting**, run the S2 producer self-check:

```bash
bash scripts/validate-design-spec.sh <design-spec-path>
```

If the validator exits non-zero, the spec is malformed against the S2 contract — fix the named field(s) and re-run before handing off. Per the S2 contract's D4 single-source-of-truth property, this is the same validator `/build` invokes at its entry step; passing it here guarantees `/build` will accept the spec.

Before exiting to `/build`, stop for human review of the design package.
Everything-else work must not proceed into implementation until the user
approves the goals, requirements, done criteria, design decisions, test
approach, and plan. The only no-review exception is work that entered the
low-friction path from verified `agent-ready` and therefore skipped `/design`.
Do not log `/design exited` or hand off to `/build` until that approval has
happened; while waiting for review, the stage is still in `/design`.

After approval, if `$ISSUE` is set, log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /design exited
fi
```

After approval, hand off to `/build` with the design spec path:

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
required. `validate-design-spec.sh` accepts this, and `/build` refuses such a doc
(read-s2 exit 3). Use it for epic-level design docs so they validate without
masquerading as a buildable `/build` input (S2 contract v1.1, #692):

```yaml
related-issue: <N>
kind: shaping
```

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

$ARGUMENTS
