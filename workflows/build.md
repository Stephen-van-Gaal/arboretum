---
name: build
requires:
  - superpowers
---

# Workflow: Build

The single development workflow under arboretum v2. Replaces the four legacy workflows (`feature`, `bug-fix`, `refactor`, `documentation`) and the Path A/B governance fork. One workflow, one triage at `/start`, one ship tail.

## When to use

Any change to behaviour, structure, or documentation of an existing project. New features, bug fixes, refactors, and docs-only changes all run through this workflow. The only structural fork is the triage at step 1 (verified `agent-ready` fast lane vs. everything-else); all other variation is handled by mode dispatch inside the shared body.

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
                       /build (Branch 2 + Branch 3)
                          ├── TDD (any applicable tier)
                          └── implementation mode (direct / executing-plans / subagent)
                                             │
                                             ▼
                       /finish (verify → /consolidate)
                                             │
                                             ▼
                              /security-review (B4, MANDATORY)
                                             │
                                             ▼
                                  /pr → /land → /cleanup → /reflect
```

Review gate: everything-else -> /design -> human review -> /build.

## Artifact Flow

| Step | Reads | Produces | Location | Authority |
|---|---|---|---|---|
| 1. `/start` (triage) | issue, git state, register | triage decision (agent-target / everything-else); for agent-target only: crisp task brief | `.arboretum/agent-briefs/<issue>.md` (agent-target only) | — |
| 2. `/design` (everything-else only) | issue, principles, architecture | design spec + plan | `docs/superpowers/specs/` + `docs/plans/` | ephemeral |
| 3. `/build` | design spec OR agent brief | code + tests; pipeline-state log entries | source dirs, `tests/`, GitHub issue body | source |
| 4. `/finish` | code + tests + design spec | reconciled governed spec via `/consolidate` | `docs/specs/` | owning |
| 5. `/security-review` (B4, mandatory) | diff | review report (often "no surface, self-gate") | (report) | — |
| 6. `/pr` → `/land` | branch state, review threads | merged PR | git, GitHub | — |
| 7. `/cleanup` → `/reflect` | branch state, session memory | clean main; lessons | git, memory | — |

### 1. Triage — `/start`

`/start` classifies the change as verified **agent-ready** or **everything-else**. Only verified `agent-ready` work may skip the review-before-build pause. Unlabelled agent-target inference can identify a good candidate for `/roadmap agent-prep`, but it does not authorize direct no-review implementation.

Agent-target fit is conservative: a change fits the fast-lane shape only when all four criteria hold unambiguously:

1. **Decision-free** — exactly one sensible implementation.
2. **Bounded** — one owner/spec, a handful of files, no architecture impact.
3. **Gate-cheap** — spec-exempt (patch-fix / implementation-detail refactor / supplementary test) OR fits within an existing `active` governed spec.
4. **Low blast radius** — reversible, cheap to verify.

If any criterion is uncertain, the change is everything-else. The escape hatch in `/build` recovers anything that slips through.

**Verified agent-ready output:** a crisp task brief at `.arboretum/agent-briefs/<issue>.md`, written by `scripts/write-agent-brief.sh`. No design spec, no plan.

**Everything-else output:** `/start` hands off to `/design` with the issue number and the user's original request.

### 2. Design — `/design` (everything-else only)

`/design` runs SURVEY, dispatches Branch 1 by change kind, writes the design spec at `docs/superpowers/specs/<date>-<topic>-design.md`, and folds in planning by invoking `superpowers:writing-plans` directly. Output is a complete design spec with S2 frontmatter populated for `/build`'s strict gate. Everything-else work stops here for human review before `/build`.

**Branch 1 modes** (per design D5):
- **brainstorm** — new or changed behaviour. Invokes `superpowers:brainstorming`.
- **investigate** — bug-fix. Invokes `superpowers:systematic-debugging` and writes the design spec as a root-cause + corrected-behaviour document.
- **coverage-baseline** — refactor (preserves behaviour). Design spec is a structure-only variant — no Behaviour section to author; `/consolidate` recognizes the structure-only shape and skips Behaviour-supersession detection (D5 of /consolidate's v2 path).
- **none** — well-defined or docs-only. Design spec is minimal; for docs-only, `/consolidate` is a no-op at `/finish` since no governed source changed.

Verified `agent-ready` skips this step entirely.

### 3. Build — `/build`

`/build` is the build-stage orchestrator. It reads the design spec's S2 frontmatter (or the agent brief) and dispatches:

- **Branch 2 — TDD assessment.** Any test tier with a non-`n/a` value triggers `superpowers:test-driven-development`. All-tiers-`n/a` is a logged skip.
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

`/finish` verifies the implementation, invokes `/consolidate` to reconcile governed specs from built state, and prepares the PR. Under v2, `/consolidate` is the sole writer of `docs/specs/*.spec.md` (per design D3) — no workflow step hand-authors a governed spec.

For docs-only changes, `/consolidate` has nothing to reconcile (no governed source changed); the effective tail is verify → `/pr`.

### 5. Security review — `/security-review` (B4, MANDATORY)

`/security-review` is **always** invoked under v2 (per design D7 / B4). It self-gates: when the diff presents no injection surface (no hook, skill, script, or agent instruction file changed), it exits fast with "no surface, self-gate". When surface exists, it runs the full analysis and may block the PR.

The mandatory invocation is the change from v1 — in v1, security review was offered optionally; under the unified workflow it's a guaranteed step. This catches injection surfaces in changes that would otherwise have skipped review.

### 6. Ship — `/pr` → `/land`

`/pr` opens the pull request with spec-aware body and health-check summary. `/land` polls CI and AI reviewers, triages feedback, and drives the PR to merge.

### 7. Cleanup + Reflect — `/cleanup` → `/reflect`

`/cleanup` switches to main, pulls latest, deletes the feature branch, verifies spec status. `/reflect` captures lessons while context is fresh.

## Transitions

- **→ explore:** If during `/design` you discover the question is too open to specify ("how should we even approach X?"), pause and enter the `explore` workflow. Return via `/consolidate` of spike findings into a design spec.
- **← explore:** When returning from a spike with enough understanding, re-enter at `/design`.
- **agent-target → everything-else:** The escape hatch in `/build`. Code written in the fast lane becomes reference-only; the work re-enters at `/design`.
