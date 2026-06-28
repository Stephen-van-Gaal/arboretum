---
name: build
requires:
  - superpowers
---

# Workflow: Build

The single development workflow under Arboretum's current general-release
pipeline, `unified`. It replaces the four legacy task-grain workflows
(`feature`, `bug-fix`, `refactor`, `documentation`) and the old governance-path
selector. One workflow, one triage at `/start`, one ship tail.

## When to use

Any change to behaviour, structure, or documentation of an existing project. New features, bug fixes, refactors, and docs-only changes all run through this workflow. The main structural fork is the triage at step 1 (verified `agent-ready` fast lane vs. everything-else); the experimental `/start-bugfix` front half can also produce a verified patch brief for authority-backed local fixes. All other variation is handled by mode dispatch inside the shared body.

The other workflows are reserved for shapes the build workflow does not cover:

- `explore` — produces knowledge (a findings document), not shipped code
- `new-project` — scaffolds a repository from nothing
- `publish` — distributes an existing project
- `retrofit` — bootstraps governance onto an existing ungoverned codebase

## Stages

```
/start (triage)
  ├── verified agent-ready ─────────────────┐
  └── everything-else → /design (Branch 1)  │
                          ├── brainstorm     │
                          ├── investigate    │
                          ├── coverage-baseline │
                          └── none           │
                          human review       │
                                             ▼
/start-bugfix (experimental patch lane)
  ├── patchable → patch brief ───────────────┤
  └── not patchable → issue update + stop    │
                                             ▼
                       /build (Branch 2 + Branch 3)
                          ├── TDD (applicable tier + direct, or plan-execution w/ no plan; else folds into Branch 3)
                          └── implementation mode (direct / executing-plans / subagent)
                                             │
                                             ▼
                       /finish (verify → /consolidate)
                                             │
                                             ▼
                              review dispatch (B4, MANDATORY)
                                             │
                                             ▼
                                  /pr → /land → /cleanup → /reflect
```

Review gate: everything-else -> /design -> human review -> /build.
Patch-lane exception: verified patch-lane briefs produced by `/start-bugfix` may enter `/build` without the everything-else design review.

## Artifact Flow

| Step | Reads | Produces | Location | Authority |
|---|---|---|---|---|
| 1. `/start` (triage) | issue, git state, register | triage decision (agent-target / everything-else); for agent-target only: crisp task brief | `.arboretum/agent-briefs/<issue>.md` (agent-target only) | — |
| 1a. `/start-bugfix` (experimental patch lane) | tracker issue, patch-lane config, authority bundle | patchability decision; patch brief or not-patchable issue update | `.arboretum/patch-briefs/<issue>.md` or tracker issue | existing authority |
| 2. `/design` (everything-else only) | issue, principles, architecture | design spec + plan | `docs/superpowers/specs/` + `docs/plans/` | ephemeral |
| 3. `/build` | design spec OR agent brief | code + tests; pipeline-state log entries | source dirs, `tests/`, GitHub issue body | source |
| 4. `/finish` | code + tests + design spec | reconciled governed spec via `/consolidate` | `docs/specs/` | owning |
| 5. review dispatch (B4, mandatory) | diff | per-lane coverage manifests (`/ai-surface-review`, general-security, correctness) | (report) | — |
| 6. `/pr` → `/land` | branch state, review threads | merged PR | git, GitHub | — |
| 7. `/cleanup` → `/reflect` | branch state, session memory | clean main; lessons | git, memory | — |

### 1. Triage — `/start`

`/start` classifies the change as verified **agent-ready** or **everything-else**. Only verified `agent-ready` work and verified patch-lane briefs produced by `/start-bugfix` may skip the review-before-build pause. Unlabelled agent-target inference can identify a good candidate for `/roadmap agent-prep`, but it does not authorize direct no-review implementation.

Agent-target fit is conservative: a change fits the fast-lane shape only when all four criteria hold unambiguously:

1. **Decision-free** — exactly one sensible implementation.
2. **Bounded** — one owner/spec, a handful of files, no architecture impact.
3. **Gate-cheap** — spec-exempt (patch-fix / implementation-detail refactor / supplementary test) OR fits within an existing `active` governed spec.
4. **Low blast radius** — reversible, cheap to verify.

If any criterion is uncertain, the change is everything-else. The escape hatch in `/build` recovers anything that slips through.

**Verified agent-ready output:** a crisp task brief at `.arboretum/agent-briefs/<issue>.md`, written by `scripts/write-agent-brief.sh`. No design spec, no plan.

**Everything-else output:** `/start` hands off to `/design` with the issue number and the user's original request.

### 1a. Experimental Patch Lane — `/start-bugfix`

`/start-bugfix` is a narrow bug-report front half. It requires tracker intake,
reads `patch_lane.investigation_budget_minutes` from project config, produces a
compact authority bundle, and applies the patchability gate before implementation
starts. Patchable reports write an S2-compatible patch brief at
`.arboretum/patch-briefs/<issue>.md` with `triage: agent-target`,
`implementation-mode: direct`, `plan: null`, `test-tiers:`, and `lane:
patch-lane`. Not-patchable reports update or create a shaped issue and stop.

The patch lane reuses the existing terminal flow from `/build` onward. It opens
a ready-for-review PR and collects configured or observable AI reviewer feedback
where available. It does not merge; merge remains human-owned.

### 2. Design — `/design` (everything-else only)

`/design` runs SURVEY, dispatches Branch 1 by change kind, writes the design spec at `docs/superpowers/specs/<date>-<topic>-design.md`, and folds in planning by invoking `superpowers:writing-plans` directly. Output is a complete design spec with S2 frontmatter populated for `/build`'s strict gate. Everything-else work stops here for human review before `/build`.

**Branch 1 modes** (per design D5):
- **brainstorm** — new or changed behaviour. Invokes `superpowers:brainstorming`.
- **investigate** — bug-fix. Invokes `superpowers:systematic-debugging` and writes the design spec as a root-cause + corrected-behaviour document.
- **coverage-baseline** — refactor (preserves behaviour). Design spec is a structure-only variant — no Behaviour section to author; `/consolidate` recognizes the structure-only shape and skips Behaviour-supersession detection.
- **none** — well-defined or docs-only. Design spec is minimal; for docs-only, `/consolidate` is a no-op at `/finish` since no governed source changed.

Verified `agent-ready` skips this step entirely.

### 3. Build — `/build`

`/build` is the build-stage orchestrator. It reads the design spec's S2 frontmatter (or the agent brief) and dispatches:

- **Branch 2 — TDD assessment.** Any test tier with a non-`n/a` value is applicable. Dispatch is mode-conditional (#928): in `mode=direct`, an applicable tier triggers `superpowers:test-driven-development` (the sole test-discipline carrier). In the plan-execution modes (`executing-plans`, `subagent-driven-development`) Branch 2 **folds into Branch 3** — no separate TDD dispatch, since the plan already carries the red → green → refactor cycle Branch 3 runs; an advisory check warns (never gates) when that can't be confirmed. All-tiers-`n/a` is a logged skip.
- **Branch 3 — implementation mode.**
  - `direct` — `/build` writes the code inline.
  - `executing-plans` — dispatches to `superpowers:executing-plans`.
  - `subagent-driven-development` — dispatches to `superpowers:subagent-driven-development`.

`/build`'s escape hatch reclassifies agent-target work into everything-else if a real design decision surfaces during implementation. Code already written is treated as reference-only (a spike); the reclassified work re-enters at `/design`.

#### Wrapped delegation — workflow-level TDD wrap

When Branch 2 invokes `superpowers:test-driven-development` directly (no arboretum wrapper between them), apply the workflow-level wrap (see `docs/ARCHITECTURE.md ## Wrapped delegation pattern`):

- **Brief** — the test taxonomy from `CLAUDE.md ## Testing`; the plan's per-step test expectations; file-naming conventions; red→green→refactor ground rules.
- **Capture user contributions** — domain test cases the AI cannot infer from the spec or codebase. Ask via `AskUserQuestion` before starting implementation.
- **Verify post-build** — taxonomy coverage, user-contribution coverage, no silent skips.

For coverage-baseline refactors, the wrap adapts: characterization-tests-first, refactor-cycle-is-keep-green-throughout, no test loosened to accommodate the new structure.

### 4. Finish — `/finish`

`/finish` verifies the implementation, invokes `/consolidate` to reconcile governed specs from built state, and prepares the PR. In the current general-release pipeline, `/design` may create or edit approved governed-spec intent/seam prose before `/build`; `/consolidate` remains the reconciler for generated/evidence sections and built-state updates.

For docs-only changes, `/consolidate` has nothing to reconcile (no governed source changed); the effective tail is verify → `/pr`.

### 5. Review dispatch (B4, MANDATORY)

B4 is a review **dispatch** run inside `/finish`: `scripts/review-dispatch.sh` computes the lane plan from the diff, and each planned lane runs as a fresh-context driver, in order:

- `/ai-surface-review` — first, when AI-facing surface changed (homegrown injection + data-flow driver);
- general-security — always (safe default; default backend: the built-in `/security-review`);
- correctness — on code diffs (default backend: `/code-review`).

Each lane returns a coverage manifest (validated by `scripts/validate-review-manifest.sh`); a missing backend degrades to the `/land` reviewers rather than silently skipping. The mandatory invocation catches injection and correctness issues before the PR opens. Owned by `docs/specs/review-stage.spec.md` (first Slipstream per-segment spec).

### 6. Ship — `/pr` → `/land`

`/pr` opens the pull request with spec-aware body and health-check summary. `/land` polls CI and AI reviewers, triages feedback, and drives the PR to merge.

### 7. Cleanup + Reflect — `/cleanup` → `/reflect`

`/cleanup` switches to main, pulls latest, deletes the feature branch, verifies spec status. `/reflect` captures lessons while context is fresh.

## Transitions

- **→ explore:** If during `/design` you discover the question is too open to specify ("how should we even approach X?"), pause and enter the `explore` workflow. Return via `/consolidate` of spike findings into a design spec.
- **← explore:** When returning from a spike with enough understanding, re-enter at `/design`.
- **agent-target → everything-else:** The escape hatch in `/build`. Code written in the fast lane becomes reference-only; the work re-enters at `/design`.
