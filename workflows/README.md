# Workflows

Workflows guide you through a best-practice sequence of steps for common development scenarios. Each workflow is a series of skills invoked in order — some arboretum-owned, some external.

## Choosing a workflow

```
What are you doing?
│
├── Starting from scratch?
│   └── new-project
│
├── Adding, changing, fixing, refactoring, or documenting in an existing project?
│   └── build
│
├── Not sure what to build, need to learn?
│   └── explore
│
├── Have an existing project you want to govern?
│   └── retrofit
│
└── Ready to share your project publicly?
    └── publish
```

## Workflow overview

```
new-project      /arboretum:init → /architect → [spike → /consolidate]* → build
build            /start → [/design] → /build → /finish → /security-review → /pr → /land → /cleanup → /reflect
explore          /start → spike → document → decide (→ build or → another spike)
publish          /publish (review → strip → sync)
retrofit         assess → bootstrap → triage → govern-one → [expand]*
```

The `/design` step in `build` is skipped for agent-target work (the triage's fast lane); everything-else flows through `/design`. Branch 1 mode dispatch inside `/design` (brainstorm / investigate / coverage-baseline / none) covers what the four legacy workflows used to handle as separate documents.

## Workflow invariants

These rules hold regardless of which workflow you use. They describe arboretum's contract with the agent, not optional discipline.

1. Every source file has `# owner: <spec-name>` from its first commit (not retrofitted at PR time).
2. Every PR has an owning governed spec at status `active` (or `draft` for WIP, with the spec activated by `/consolidate` as part of the PR).
3. Tests land before or alongside implementation (TDD discipline, all Branch 2 paths).
4. The Behaviour section of the governed spec is human-authored.
5. PRs scope by intent, not "everything in the tree" — hunk-staging when needed.

Invariant #6 of the legacy two-path model ("pick one governance path per slice — don't mix them") has no analogue under v2. Governed specs are written only by `/consolidate` (design D3), so there is no governance-path selector to mix.

## Skill legend

| Notation | Meaning |
|---|---|
| `/skill` | Arboretum skill (user invokes) |
| `capability` | Abstract capability (current provider in parentheses, degrades gracefully if absent) |
| `step` | Manual step (Claude guides, no skill needed) |
| `[x]*` | Repeat as needed |
| `→` | Proceed to next step |

## Spec sizing

A spec should have a **single reason to change**. If two behaviours can evolve independently, they should be separate specs. If two pieces of code always change together and share internal state, they belong in the same spec.

**Signs a spec is too large:**
- Its Behaviour section has multiple unrelated subsystems
- Different parts could be implemented and tested independently
- It owns files in multiple unrelated directories

**Signs a spec is too small:**
- It cannot be tested without mocking its own internals
- Its provides are only consumed by one other spec and could be inlined
- It has no independent reason to exist

## Draft mode

When all involved documents (the spec and its dependencies) have status `draft`:

- Claude **notes ambiguities** and **continues with its best interpretation**, rather than stopping
- Hard stops are reserved for **contradictions** (the spec says two incompatible things) and **infeasibility** (the approach cannot work as described)
- Minor TBDs, stylistic choices, and edge case questions are logged and implementation proceeds

This prevents the workflow from stalling during early development when everything is being shaped simultaneously. Once documents move to `active`, the strict "stop and report" rule applies.

## Revision protocol

When Claude discovers during implementation that a spec is wrong (not ambiguous, but wrong — an API doesn't exist, a performance constraint makes the design infeasible):

1. **Stop implementation** of the affected behaviour
2. **Document the finding** — what was attempted, what failed, why it won't work
3. **Propose alternatives** — 1-3 approaches with trade-offs
4. **The spec's status will flip to `stale`** automatically (via `/health-check`) when drift is detected, or remain `active` if `/consolidate` reconciles immediately
5. **Continue implementing unaffected parts** if they are independent

The user reviews, selects an approach, and updates the spec. The spec stays at `active` (or returns to it via `/consolidate` once the new code lands).

## Anti-patterns

- **Orphan code.** Files exist that no spec claims. Fix: assign to a spec or delete.
- **Inline schemas.** A spec defines a data structure another spec also needs. Fix: extract to a shared definition.
- **Ghost dependencies.** A spec uses something from another module without declaring it. Fix: audit imports against declared requires.
- **Junk-drawer specs.** A spec like "shared-utils" accumulates unrelated code. Fix: split into purpose-specific specs.
- **Architecture drift.** The architecture document no longer matches the specs. Fix: update architecture when specs change.
- **Premature strictness.** Applying stable-definition rules to drafts still being shaped. Fix: use v0 for draft definitions; strict versioning only after `stable`.

## Workflow transitions

Most cross-workflow pivots from the legacy four-workflow model are now mode dispatches inside `/design` (Branch 1) — switching from a `brainstorm` mode to an `investigate` mode is not a workflow transition, just a re-classification. The remaining transitions are between top-level workflows.

| From | To | When |
|------|-----|------|
| build → | explore | During `/design` you discover the question is too open to specify. Pause `build`, enter `explore`. Return via `/consolidate` of spike findings into a design spec. |
| explore → | build | A spike produces enough understanding. `/consolidate` findings into a design spec and enter `build` at `/design`. |
| build (agent-target) → | build (everything-else) | The escape hatch — a real design decision surfaces during agent-target prep or implementation. Code already written is treated as reference-only; the work re-enters at `/design`. |

**Transition protocol:**
1. Note where you are (so you can return)
2. Commit or stash in-progress work
3. Enter the target workflow at its natural entry point
4. Return to the original workflow when complete

## Signs governance is working

- You're rarely surprised by what Claude implements (your specs are clear)
- When you change one spec, other specs don't break unexpectedly (ownership is clean)
- New team members can understand the project by reading specs, not code (traceability works)
- `/health-check` runs clean most of the time (drift is caught early)
- You spend more time deciding what to build than debugging what was built

## Signs governance needs adjustment

- You're spending more time on governance than on the actual work (over-governed — drop a layer)
- Specs are routinely out of date (under-maintained — simplify specs or add automation)
- Claude keeps asking for permission to update specs (spec-first gate is friction, not value — check if specs are too granular)

## Governance debt

Governance debt is accumulated drift between specs, register, code, and contracts. It happens naturally — branches merge, files get added without ownership, specs go stale.

### Detecting it

Run `/health-check`. It reports all categories of drift.

### Triage by severity

| Severity | Examples | Action |
|----------|----------|--------|
| **Blocking** | Spec contradictions, circular dependencies | Fix immediately — these prevent correct implementation |
| **Moderate** | Unowned files, stale version pins, register gaps | Fix before next PR — these cause confusion |
| **Low** | Missing optional docs, cosmetic spec issues | Fix when convenient — these don't affect correctness |

### Recovery patterns

- **Many unowned files** → run `/consolidate` to batch-create specs
- **Stale register** → run `scripts/generate-register.sh` to regenerate
- **Spec/code divergence** → `/health-check` flips spec to `stale`; run `/consolidate` to reconcile (either update the spec to match code, or revert the code to match the spec)
- **Abandoned branch governance** → delete orphaned specs, regenerate register

### Prevention

Run `/health-check` before every PR. The `/finish` skill already suggests this.

## Detailed workflows

- [new-project](new-project.md)
- [build](build.md)
- [explore](explore.md)
- [publish](publish.md)
- [retrofit](retrofit.md)
