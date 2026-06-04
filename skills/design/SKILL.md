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

Orchestrates the transition from idea to implementable governed spec. This is a wrapper that coordinates external design skills with arboretum's governance.

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
in-flight design spec, the governed spec is born from built state at `/finish`,
and planning folds into this skill.

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

### 1. Survey

Before any design work, read existing governed code that may be relevant to the topic:

1. List `docs/specs/` and read any spec whose name plausibly overlaps the request topic — don't infer from filenames alone.
2. Read `docs/ARCHITECTURE.md` — scan the section relevant to the request area.
3. Read `docs/REGISTER.md` — identify the owning spec for any files the request mentions explicitly.

Survey is owned exclusively by this skill for everything-else work. `/start`
does the cheap routing pass; `/design` owns the contextual read of governed
specs, architecture, and register entries.

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

After writing-plans returns, verify the plan landed at `docs/plans/`, not `docs/superpowers/plans/`. If it landed in the wrong place, move it with `git mv` (preserves history) and update the `plan:` field in the design spec frontmatter to match the new path — `/build` reads that field, and a stale `plan:` pointer causes a "plan path not found" error.

### 5. Exit to `/build`

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
