---
version: 1
name: workflow-pipeline
status: active
document-shape: group
parent: arboretum
contains:
  - architecture-workflow
owns: []
---

# Workflow Pipeline

## Job (JTBD)

<!-- HUMAN -->
Organize all build-pipeline work by **altitude** (arch / group / spec) so a single
recursive activity — **shape → emit the children of the altitude below; the leaf
additionally builds** — instantiates uniformly at every level. This group owns the
**three-altitude model**: that altitude is the primary organizing axis (whether work
changes code is *derived* from the arrangement an altitude runs, not chosen
independently), and that the same shaping activity recurs from `/architect` at the
top down to `/design`'s front-half at the leaf.

The payoff is one mental model for a domain expert who is a software non-expert:
"shaping emits children; at the leaf you build." Groups are demand-driven, so on a
typical small project the interior altitudes (arch, group) stay **dormant** and the
user only ever meets the leaf (spec-altitude / conductor) form — the higher tiers
cost them nothing until a project grows enough to need them.

## Boundaries (non-goals)

<!-- HUMAN -->
- Does NOT re-cut the lifecycle workflows that deliberately sit outside `build` —
  `explore`, `new-project`, `publish`, `retrofit` keep their existing semantics
  (`docs/specs/workflow-unification.spec.md`). The altitude ladder scopes to the
  build/Slipstream pipeline only.
- Does NOT own the worktree / collision / liveness machinery the pipeline runs on
  — that is the sibling `workspace-isolation` group.
- Does NOT own pipeline telemetry or cross-stage data plumbing as *behaviour* —
  `pipeline-state-tracking` and `pipeline-context-ledger` are component specs the
  conductor arrangement consumes; this group documents only how they seam together.
- Does NOT itself build — this is a group (shaping-altitude) document; its child
  specs build individually, never this doc.

## Children

<!-- HUMAN -->
Authored **incrementally** (precursor D2): the group doc lands first (#816) with
`contains: []`; each child below joins `contains:` — and declares
`parent: workflow-pipeline` — in the PR that authors its spec, as a paired
round-trip update. `architecture-workflow` has joined `contains:` (#817); the
remaining rows are planned membership, not yet in the frontmatter.

| Name | Kind | One-line purpose | Status |
|------|------|------------------|--------|
| `architecture-workflow` | component (spec) | Arch altitude: `/architect` shapes groups + their boundaries; emits group-level work. | in `contains:` (#817) |
| `orchestrator-workflow` | component (spec) | Group altitude (the current gap): shape → emit sibling specs → sequence them; the recursive interior arrangement. | planned (#818) |
| `conductor-workflow` | component (spec) | Spec altitude / leaf: shape → build (via drivers) → ship; one issue's journey. The machine #516 builds. | planned (#819) |

`workflow-unification.spec.md` currently governs all three altitudes and is
migrated into these children over time (precursor D2) — not split in one move, and
not in #816.

## Integration

<!-- HUMAN -->
The three altitudes form one **ladder**, each rung emitting the rung below:

- **Arch** shapes groups and their boundaries (`/architect`), emitting group-level
  work.
- **Group** shapes sibling specs and their seams (epic decomposition), emitting
  spec-level work.
- **Spec** (the **leaf**) shapes one design spec and then emits **code**.

Interior altitudes (arch, group) bottom out in more *documents*; the leaf bottoms
out in *code*. The rungs are connected by a single interface — the **emit-seam**
(see Shared Contracts): a parent altitude hands a child its brief. Data flows
down-path: shape → emit children → sequence; the brief is the handoff payload at
every boundary. The off-diagonal cases (a group-altitude arrangement that *does*
build, e.g. `extract-component` #630; a spec-altitude arrangement that is docs-only,
e.g. this very document) are ordinary lookups under "altitude picks the arrangement,
arrangement determines code/no-code," not contradictions.

## Orchestration

<!-- HUMAN -->
The **runtime ladder** (#516: orchestrator / conductor / driver) maps onto the
artifact ladder **offset by one rung** (precursor D3), because code-production needs
one extra decomposition level that document-production does not:

| Artifact altitude (what's produced) | Runtime tier (who executes) |
|---|---|
| **Arch** — emits groups | orchestrator (sequences children) |
| **Group** — emits sibling specs | orchestrator — epic-level work sequencing |
| **Spec** — emits code | **conductor** — one issue's journey |
| *(a stage of a spec's journey)* | **driver** — one stage in fresh context |

This collapses to two arrangements:

- **Interior altitudes (arch, group)** run the **orchestrator arrangement** —
  shape → emit children → sequence; recursive and uniform; **no build by default**
  (the off-diagonal build cases are explicit exceptions, not a property of the
  altitude).
- **Spec altitude** runs the **conductor arrangement** — shape → build (via drivers)
  → ship; the leaf, and the everyday activity on a small project.

The separate-axes flexibility (dispatch *any* altitude in *any* runtime tier)
is **not** a second user-facing axis (precursor D4). It survives as an **override on
the arrangement's per-stage `dispatch-mode` / `default-model` fields** — invisible to
beginners, reachable by a future Full-profile adopter.

## Shared Contracts

<!-- HUMAN -->
- **The emit-seam — the one parent→child brief interface, reused at every altitude
  boundary** (interior or leaf). A parent altitude hands a child its brief; the same
  interface carries arch→group, group→spec, and spec→build handoffs. Concrete
  instances: the epic→slice brief (group→spec), and the spec-altitude brief-only
  fast lanes (`.arboretum/agent-briefs/<issue>.md` for verified agent-ready work,
  `.arboretum/patch-briefs/<issue>.md` for the patch lane) that enter `/build`
  directly. **Specify it once; reuse it everywhere.** The epic→slice handoff that
  fails today — stale `plan:` pointer / wrong `related-issue` in pipeline-state
  telemetry, the #645 class called out in #516's own success criteria — is the first
  concrete instance and the canary for the seam.
- **Shared vocabulary across the children:** `orchestrator` (interior-altitude
  sequencing) / `conductor` (one issue's journey, the leaf) / `driver` (one stage in
  fresh context); `arrangement` (the machine-readable per-stage composition);
  `altitude` (arch / group / spec, the primary key). `default-model` is the
  arrangement-level routing field — distinct from a skill-local subagent `model`
  parameter; the child specs carry the arrangement-level name.
- **The fused-ladder model (D3/D4):** the user-facing model is **one ladder** —
  altitude → arrangement → runtime tier. Tier is an overridable per-stage field on
  the arrangement, not an independent composing axis.

## Shared Schemas

<!-- HUMAN -->
Two data shapes are shared across the children and **specified by them** (named here
as the group's shared schemas, defined downstream — not restated):

- **The brief payload** — the emit-seam's data shape (the fields a parent hands a
  child: `related-issue`, plan pointer, scope). Authoritatively specified by
  `orchestrator-workflow` (#818) and `conductor-workflow` (#819); the #645 fix
  (resolve the active slice's `plan` / `related-issue` through the brief without
  mutating epic-level frontmatter) is its first test.
- **The arrangement record** — the per-stage `dispatch-mode` / `default-model`
  composition (#516 slice-2). The override surface for D4's deferred separate-axes
  capability.

## Implementation Notes

<!-- HUMAN -->
- **Incremental authoring (precursor D2).** #816 lands the group doc with
  `contains: []`. Children #817 (`architecture-workflow`), #818
  (`orchestrator-workflow`), #819 (`conductor-workflow`) each add themselves to
  `contains:` and declare `parent: workflow-pipeline` in the same PR (the paired
  round-trip `validate-group-membership.sh` enforces). The open questions carried by
  the precursor (emit-seam spec, intake altitude gate, escalation up-path,
  off-diagonal validation) are resolved *within* those child specs as authored.
- **Why a group.** The area-vs-split gate returns "split": the three altitudes
  change for different reasons, and the cross-altitude content (the emit-seam) is
  homeless in any single spec. The group is its home.
- **Relationship to in-flight work.** #516 (Slipstream — conductor = leaf
  arrangement); #680 / #681 / #742 (altitude ladder + area-vs-split gate +
  group-layer validator); #692 (`kind: shaping`, promoted toward "interior-altitude
  arrangement"); #645 (epic→slice mismatch = first emit-seam instance); #630
  (`extract-component`, the canonical group+code off-diagonal).

### Design record

<!-- AUTO -->
- `docs/superpowers/specs/2026-06-19-workflow-pipeline-group-doc-design.md` — group doc authoring (#816, buildable child of epic #815).
- `docs/superpowers/specs/2026-06-19-workflow-altitude-model-design.md` — precursor shaping doc (epic #815); supplies the D1–D4 model this group renders.

## Decisions

<!-- APPEND-AUTO -->
| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
| D1 | The workflow system is a **group**; `docs/groups/workflow-pipeline.md` is its group doc, `parent: arboretum`, 2nd real group instance | Keep it inside `workflow-unification.spec.md`; new top-level architecture section | Area-vs-split returns "split" — the three altitudes change for different reasons; a group is the home for cross-altitude content (the emit-seam). | 2026-06-19 | `docs/superpowers/specs/2026-06-19-workflow-pipeline-group-doc-design.md` (D1) |
| D2 | Ship with `contains: []`; children join incrementally as #817/#818/#819 land (each does the paired `parent:`/`contains:` round-trip update) | List all three children now + create 3 draft stub specs to satisfy the round-trip immediately | `validate-group-membership.sh` fails on a `contains:` entry whose spec doesn't exist; precursor D2 mandates "authored incrementally, not split in one move"; empty `contains:` validates vacuously; stubs are governance noise. | 2026-06-19 | `docs/superpowers/specs/2026-06-19-workflow-pipeline-group-doc-design.md` (D2) |
| D3 | Shared Contracts names the **emit-seam** (one parent→child brief), shared vocabulary (orchestrator/conductor/driver, arrangement), and the fused ladder (altitude→arrangement→tier) | Document only the artifact ladder; defer seam to the child specs | Acceptance requires it; the seam is the cross-level content a group doc exists to hold; specifying it once (then reused) is the precursor's core claim. | 2026-06-19 | `docs/superpowers/specs/2026-06-19-workflow-pipeline-group-doc-design.md` (D3) |
| D4 | Docs-only: author the group doc as the design-package Durable Document Change Set, committed pre-build; `/build` is verification-only | Treat as a code build; treat the design session as `kind: shaping` | The deliverable is one durable intent/seam document with no code; it does not emit children, so it is not `shaping`; durable intent/seam edits are committed pre-build by design. | 2026-06-19 | `docs/superpowers/specs/2026-06-19-workflow-pipeline-group-doc-design.md` (D4) |
